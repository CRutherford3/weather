// Cloudflare Pages Function: same job as netlify/functions/proxy.mts, served at /api/proxy.
// Fetches public weather feeds that browsers can't read directly. Only these hosts are allowed.
const ALLOWED = new Set([
  'api.weather.gov',
  'www.nhc.noaa.gov',
  'www.spc.noaa.gov',
  'www.wpc.ncep.noaa.gov',
  'mesonet.agron.iastate.edu',
  'earthquake.usgs.gov',
  'services3.arcgis.com',
  'api.rainviewer.com',
  'api.open-meteo.com',
  'air-quality-api.open-meteo.com',
  'geocoding-api.open-meteo.com',
]);

export async function onRequestGet({ request }) {
  const target = new URL(request.url).searchParams.get('url');
  if (!target) return new Response('Missing url', { status: 400 });

  let url;
  try { url = new URL(target); } catch { return new Response('Bad url', { status: 400 }); }
  if (url.protocol !== 'https:' || !ALLOWED.has(url.hostname)) return new Response('Host not allowed', { status: 403 });

  try {
    const upstream = await fetch(url, {
      headers: {
        'User-Agent': 'UpdraftWeather/1.0 (github.com/CRutherford3/weather)',
        Accept: request.headers.get('accept') || 'application/json, application/geo+json, */*',
      },
      cf: { cacheTtl: 60, cacheEverything: true },
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        'Content-Type': upstream.headers.get('content-type') || 'application/json',
        'Cache-Control': 'public, max-age=60',
      },
    });
  } catch (e) {
    return new Response(`Upstream error: ${e.message}`, { status: 502 });
  }
}
