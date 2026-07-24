export async function onRequest(context) {
  const url = new URL(context.request.url);
  
  // 根路径 / 返回 winutil.ps1
  if (url.pathname === '/' || url.pathname === '/win') {
    const fs = await import('fs/promises');
    const path = await import('path');
    const scriptPath = path.resolve('./winutil.ps1');
    const script = await fs.readFile(scriptPath, 'utf-8');
    return new Response(script, {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
      },
    });
  }
  
  // 其他路径正常处理
  return context.next();
}
