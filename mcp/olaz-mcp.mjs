#!/usr/bin/env node
// Olaz MCP server (stdio, no dependencies). Bridges MCP tools to Olaz's local assistant socket.
// The AI can read conversations and PROPOSE replies; every send needs the user's click in Olaz ▸ Duyệt nháp (⌘⇧D),
// and Olaz paces/caps sends (SendGuard) to keep the Zalo account safe.
//
// Register:  claude mcp add olaz -- node /path/to/zalo-swift-re/mcp/olaz-mcp.mjs
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const SOCKET = process.env.OLAZ_ASSISTANT_SOCKET
  || path.join(os.homedir(), 'Library', 'Application Support', 'Olaz', 'assistant.sock');

let nextId = 1;
function callOlaz(method, params = {}, timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const sock = net.createConnection(SOCKET);
    let buf = '';
    const timer = setTimeout(() => { sock.destroy(); reject(new Error('Olaz không phản hồi (timeout)')); }, timeoutMs);
    sock.on('connect', () => sock.write(JSON.stringify({ id, method, params }) + '\n'));
    sock.on('data', (d) => {
      buf += d;
      const nl = buf.indexOf('\n');
      if (nl < 0) return;
      clearTimeout(timer);
      sock.end();
      try {
        const msg = JSON.parse(buf.slice(0, nl));
        msg.error ? reject(new Error(msg.error)) : resolve(msg.result);
      } catch (e) { reject(e); }
    });
    sock.on('error', (e) => {
      clearTimeout(timer);
      reject(new Error(e.code === 'ENOENT' || e.code === 'ECONNREFUSED'
        ? 'Không kết nối được Olaz. Mở Olaz và bật Cài đặt ▸ Trợ lý AI.'
        : e.message));
    });
  });
}

const str = (description) => ({ type: 'string', description });
const TOOLS = [
  {
    name: 'olaz_status',
    description: 'Trạng thái Olaz: đã đăng nhập chưa, số nháp chờ duyệt, các giới hạn chống spam đang áp dụng.',
    inputSchema: { type: 'object', properties: {} },
    method: 'status',
  },
  {
    name: 'list_conversations',
    description: 'Danh sách hội thoại Zalo (mới nhất trước) với tin cuối, số chưa đọc, nhãn. Dùng unreadOnly=true để lấy khách đang chờ trả lời.',
    inputSchema: {
      type: 'object',
      properties: {
        unreadOnly: { type: 'boolean', description: 'Chỉ hội thoại có tin chưa đọc' },
        query: str('Lọc theo tên (không dấu cũng được)'),
        limit: { type: 'integer', description: 'Mặc định 30, tối đa 200' },
      },
    },
    method: 'list_conversations',
  },
  {
    name: 'read_messages',
    description: 'Đọc các tin gần nhất của một hội thoại (Olaz sẽ mở hội thoại đó trên màn hình và đánh dấu đã đọc).',
    inputSchema: {
      type: 'object',
      properties: { conversationId: str('id từ list_conversations'), limit: { type: 'integer', description: 'Mặc định 30, tối đa 100' } },
      required: ['conversationId'],
    },
    method: 'read_messages',
  },
  {
    name: 'propose_reply',
    description: 'Đề xuất một tin trả lời. KHÔNG gửi ngay: tin vào hàng chờ duyệt. Sau khi tạo, LUÔN gửi preview cho người dùng '
      + '(người nhận, nội dung nguyên văn, tin được trích dẫn, người được tag, draftId, cảnh báo) và chờ họ nói "duyệt". '
      + 'Chỉ trả lời khách đã nhắn trong 7 ngày. Viết riêng cho từng khách, tránh copy y hệt cho nhiều người, hạn chế link.',
    inputSchema: {
      type: 'object',
      properties: {
        conversationId: str('id hội thoại'),
        text: str('Nội dung trả lời (≤ 2000 ký tự)'),
        quoteMessageId: str('Tuỳ chọn: id tin cần trả lời/trích dẫn (từ read_messages)'),
        mentions: {
          type: 'array',
          description: 'Tuỳ chọn (chỉ nhóm): người cần tag. Mỗi người phải có "@<name>" nguyên văn trong text. Lấy uid từ find_members.',
          items: { type: 'object', properties: { uid: str('uid thành viên ("-1" = @All)'), name: str('Tên đúng như find_members trả về') }, required: ['uid', 'name'] },
        },
        note: str('Tuỳ chọn: giải thích ngắn cho người duyệt (không gửi cho khách)'),
      },
      required: ['conversationId', 'text'],
    },
    method: 'propose_reply',
  },
  {
    name: 'find_members',
    description: 'Tìm thành viên nhóm để tag (@mention). Trả uid + tên hiển thị; dùng tên đó nguyên văn sau "@" trong propose_reply.',
    inputSchema: {
      type: 'object',
      properties: { conversationId: str('id nhóm'), query: str('Một phần tên (để trống = gợi ý mặc định)') },
      required: ['conversationId'],
    },
    method: 'find_members',
  },
  {
    name: 'view_media',
    description: 'Xem ảnh/sticker (ảnh thu nhỏ), video (vài khung hình rải đều + thời lượng) hoặc file (lưu cục bộ, trả path; file text nhỏ trả nội dung) '
      + 'của MỘT tin. Chỉ gọi cho tin có media.viewable=true từ read_messages và khi cần cho việc trả lời.',
    inputSchema: {
      type: 'object',
      properties: {
        conversationId: str('id hội thoại'),
        messageId: str('id tin từ read_messages'),
        frames: { type: 'integer', description: 'Số khung hình cho video (1–8, mặc định 4)' },
      },
      required: ['conversationId', 'messageId'],
    },
    method: 'view_media',
    timeoutMs: 150000,
  },
  {
    name: 'list_drafts',
    description: 'Các nháp gần đây và trạng thái: pending (chờ duyệt), queued (đã duyệt, chờ lượt gửi), sent, discarded, failed.',
    inputSchema: { type: 'object', properties: {} },
    method: 'list_drafts',
  },
  {
    name: 'get_draft',
    description: 'Trạng thái một nháp.',
    inputSchema: { type: 'object', properties: { draftId: str('id nháp') }, required: ['draftId'] },
    method: 'get_draft',
  },
  {
    name: 'approve_draft',
    description: 'Gửi một nháp mà người dùng ĐÃ đọc preview và nói rõ "duyệt" (hoặc "ok gửi", "gửi đi") trong tin nhắn MỚI NHẤT của họ. '
      + 'KHÔNG BAO GIỜ tự gọi khi người dùng chưa đọc preview hoặc chưa nói duyệt; không suy diễn từ yêu cầu ban đầu như "soạn và gửi". '
      + 'Nếu người dùng duyệt nhiều nháp, gọi lần lượt từng cái. text phải khớp nguyên văn nháp đã preview. '
      + 'Olaz vẫn áp giới hạn chống khoá (có thể phải chờ 12–20 giây giữa các tin).',
    inputSchema: {
      type: 'object',
      properties: { draftId: str('id nháp'), text: str('Nội dung nguyên văn đã preview cho người dùng') },
      required: ['draftId', 'text'],
    },
    method: 'approve_draft',
    timeoutMs: 60000,
  },
  {
    name: 'withdraw_draft',
    description: 'Rút lại một nháp còn đang chờ duyệt.',
    inputSchema: { type: 'object', properties: { draftId: str('id nháp') }, required: ['draftId'] },
    method: 'withdraw_draft',
  },
];

function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }

async function handle(req) {
  const { id, method, params } = req;
  if (id === undefined) return; // notification
  try {
    switch (method) {
      case 'initialize':
        return send({ jsonrpc: '2.0', id, result: {
          protocolVersion: params?.protocolVersion || '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'olaz', version: '1.0.0' },
          instructions: 'Đọc và soạn nháp trả lời khách Zalo qua Olaz. Quy trình: propose_reply → gửi preview nguyên văn cho người dùng '
            + '→ chỉ khi người dùng nói "duyệt" thì approve_draft. Không bao giờ duyệt thay người dùng. '
            + 'Chỉ báo "đã gửi" khi approve_draft trả về state=sent.',
        } });
      case 'ping':
        return send({ jsonrpc: '2.0', id, result: {} });
      case 'tools/list':
        return send({ jsonrpc: '2.0', id, result: { tools: TOOLS.map(({ method: _m, ...t }) => t) } });
      case 'tools/call': {
        const tool = TOOLS.find((t) => t.name === params?.name);
        if (!tool) return send({ jsonrpc: '2.0', id, error: { code: -32602, message: 'Unknown tool' } });
        try {
          const result = await callOlaz(tool.method, params.arguments || {}, tool.timeoutMs);
          const content = [];
          if (result && Array.isArray(result.images)) {
            const { images, mimeType, ...meta } = result;
            content.push({ type: 'text', text: JSON.stringify(meta, null, 1) });
            for (const data of images) content.push({ type: 'image', data, mimeType: mimeType || 'image/jpeg' });
          } else {
            content.push({ type: 'text', text: JSON.stringify(result, null, 1) });
          }
          return send({ jsonrpc: '2.0', id, result: { content } });
        } catch (e) {
          return send({ jsonrpc: '2.0', id, result: { isError: true, content: [{ type: 'text', text: String(e.message || e) }] } });
        }
      }
      default:
        return send({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Method not found' } });
    }
  } catch (e) {
    send({ jsonrpc: '2.0', id, error: { code: -32603, message: String(e.message || e) } });
  }
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try { req = JSON.parse(line); } catch { return; }
  handle(req);
});
