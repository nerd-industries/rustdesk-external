export default {
  async fetch(request) {
    const url = new URL(request.url);
    const host = url.hostname.split('.')[0];
    const ua = (request.headers.get('User-Agent') || '').toLowerCase();

    // Only allow curl, PowerShell, and wget
    const allowed = ua.includes('curl') ||
                    ua.includes('powershell') ||
                    ua.includes('windowspowershell') ||
                    ua.includes('wget');

    if (!allowed) {
      return new Response('Not found', { status: 404 });
    }

    const scripts = {
      'rustdesk': 'install-windows.ps1',
      'rustdesk-shop': 'install-windows-shop.ps1',
      'rustdesk-uninstall': 'uninstall-windows.ps1',
      'rustdesk-macos': 'install-macos.sh',
      'rustdesk-macos-shop': 'install-macos-shop.sh',
      'rustdesk-macos-uninstall': 'uninstall-macos.sh',
    };

    const filename = scripts[host];
    if (filename) {
      const apiUrl = `https://api.github.com/repos/nerd-industries/rustdesk-external/contents/${filename}`;
      const rawUrl = `https://raw.githubusercontent.com/nerd-industries/rustdesk-external/refs/heads/main/${filename}`;

      // Try GitHub API first (real-time updates)
      const response = await fetch(apiUrl, {
        headers: {
          'Accept': 'application/vnd.github.v3.raw',
          'User-Agent': 'Cloudflare-Worker'
        },
        cf: { cacheTtl: 60 }
      });

      // Fall back to raw URL if API is rate limited
      if (response.status === 403 || response.status === 429) {
        const fallback = await fetch(rawUrl, {
          headers: { 'User-Agent': 'Cloudflare-Worker' },
          cf: { cacheTtl: 300 }
        });
        const body = await fallback.text();
        return new Response(body, {
          headers: {
            'Content-Type': 'text/plain',
            'Cache-Control': 'public, max-age=300'
          }
        });
      }

      const body = await response.text();
      return new Response(body, {
        headers: {
          'Content-Type': 'text/plain',
          'Cache-Control': 'public, max-age=60'
        }
      });
    }
    return new Response('Not found', { status: 404 });
  }
}
