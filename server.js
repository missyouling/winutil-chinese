const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8080;
const WINUTIL_PATH = path.resolve(__dirname, 'winutil.ps1');

const server = http.createServer((req, res) => {
  if (req.url === '/win' || req.url === '/win/') {
    // 提供 winutil.ps1 下载
    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Content-Disposition': 'inline',
    });
    const stream = fs.createReadStream(WINUTIL_PATH);
    stream.pipe(res);
    stream.on('error', () => {
      res.writeHead(500);
      res.end('Error reading winutil.ps1');
    });
  } else if (req.url === '/api/health' || req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', version: '1.0.0' }));
  } else {
    // 首页信息
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WinUtil 中文版</title>
  <style>
    body { font-family: 'Microsoft YaHei', sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; background: #1a1a2e; color: #eee; }
    h1 { color: #00d4aa; }
    code { background: #16213e; padding: 2px 6px; border-radius: 3px; color: #e94560; }
    .cmd { background: #0f3460; padding: 15px; border-radius: 5px; margin: 15px 0; }
  </style>
</head>
<body>
  <h1>🎯 WinUtil 中文版</h1>
  <p>全中文化的 Windows 系统优化工具</p>
  <div class="cmd">
    <strong>使用方法（在 Windows PowerShell 中以管理员身份运行）：</strong><br><br>
    <code>irm http://<span id="host">localhost</span>:${PORT}/win | iex</code>
  </div>
  <p>功能与原版完全一致，仅界面和提示信息已翻译为中文。</p>
  <p>版本: 26.07.24 | 基于 Chris Titus Tech WinUtil</p>
  <script>
    document.getElementById('host').textContent = location.hostname;
  </script>
</body>
</html>`);
  }
});

server.listen(PORT, () => {
  console.log(`✅ WinUtil 中文版 Web 服务器运行中`);
  console.log(`   http://localhost:${PORT}/`);
  console.log(`   PowerShell 中使用: irm http://localhost:${PORT}/win | iex`);
});
