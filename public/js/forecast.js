// Builds one merged forecast model from NWS (official, US) + Open-Meteo (models, worldwide), and renders it.
import { U, fmtT, fmtW, fmtP, wx, nwsIcon, icon, esc, compass, hourLabel, clockLabel, dayName, dateLabel, moonPhase, aqiInfo, uvInfo, timeAgo, clamp, tempColor } from './util.js';
import { alertColor } from './config.js';

const f2c = (f) => (f - 32) * 5 / 9;
const mph2kmh = (s) => { const m = String(s || '').match(/(\d+)(?:\s*to\s*(\d+))?/); return m ? (+(m[2] || m[1])) * 1.60934 : null; };
const DIRS = { N: 0, NNE: 22.5, NE: 45, ENE: 67.5, E: 90, ESE: 112.5, SE: 135, SSE: 157.5, S: 180, SSW: 202.5, SW: 225, WSW: 247.5, W: 270, WNW: 292.5, NW: 315, NNW: 337.5 };

export function buildModel(D) {
  const om = D.om, nws = D.nws, c = om.current, h = om.hourly, d = om.daily;
  const M = { tz: om.timezone, utcOffset: om.utc_offset_seconds, nws, isUS: !!nws, sources: [] };

  // ----- current conditions: prefer a real measured observation -----
  const o = nws?.obs;
  const val = (x) => (x && x.value != null ? x.value : null);
  M.current = {
    temp: val(o?.temperature) ?? c.temperature_2m,
    feels: val(o?.heatIndex) ?? val(o?.windChill) ?? c.apparent_temperature,
    dew: val(o?.dewpoint) ?? c.dew_point_2m,
    rh: val(o?.relativeHumidity) ?? c.relative_humidity_2m,
    wind: val(o?.windSpeed) ?? c.wind_speed_10m,
    dir: val(o?.windDirection) ?? c.wind_direction_10m,
    gust: val(o?.windGust) ?? c.wind_gusts_10m,
    press: (val(o?.seaLevelPressure) ?? val(o?.barometricPressure)) != null ? (val(o.seaLevelPressure) ?? val(o.barometricPressure)) / 100 : c.pressure_msl,
    vis: val(o?.visibility) ?? c.visibility,
    text: o?.textDescription || wx(c.weather_code, c.is_day).text,
    icon: o?.textDescription ? nwsIcon(o.textDescription, !!c.is_day) : wx(c.weather_code, c.is_day).icon,
    uv: c.uv_index, cloud: c.cloud_cover, cape: c.cape, isDay: c.is_day,
    observed: o ? { station: nws.station?.name, id: nws.station?.stationIdentifier, time: new Date(o.timestamp).getTime() } : null,
  };
  M.sources.push(o ? `Current: measured at ${nws.station?.stationIdentifier} (NWS)` : 'Current: Open-Meteo model analysis');

  // ----- hourly -----
  const nowKey = c.time.slice(0, 13);
  let start = h.time.findIndex((t) => t.slice(0, 13) >= nowKey); if (start < 0) start = 0;
  const omIdx = new Map(h.time.map((t, i) => [t.slice(0, 13), i]));
  const hours = [];
  if (nws?.hourly?.length) {
    for (const p of nws.hourly.slice(0, 156)) {
      const key = p.startTime.slice(0, 13); const i = omIdx.get(key);
      if (key < nowKey) continue;
      hours.push({
        time: p.startTime.slice(0, 16), temp: f2c(p.temperature), pop: p.probabilityOfPrecipitation?.value ?? 0,
        precip: i != null ? h.precipitation[i] : null, text: p.shortForecast, icon: nwsIcon(p.shortForecast, p.isDaytime),
        wind: mph2kmh(p.windSpeed), dir: DIRS[p.windDirection] ?? null, gust: i != null ? h.wind_gusts_10m[i] : null,
        rh: p.relativeHumidity?.value ?? (i != null ? h.relative_humidity_2m[i] : null), dew: p.dewpoint?.value ?? (i != null ? h.dew_point_2m[i] : null),
        uv: i != null ? h.uv_index[i] : null, feels: i != null ? h.apparent_temperature[i] : null, src: 'NWS',
      });
    }
    M.sources.push('Hourly: official NWS forecast (with model UV, gusts, rain amounts)');
  }
  // Extend (or fill entirely) with Open-Meteo
  const lastKey = hours.at(-1)?.time.slice(0, 13) || '';
  for (let i = start; i < h.time.length; i++) {
    if (h.time[i].slice(0, 13) <= lastKey) continue;
    const w = wx(h.weather_code[i], h.is_day[i]);
    hours.push({ time: h.time[i], temp: h.temperature_2m[i], pop: h.precipitation_probability[i] ?? 0, precip: h.precipitation[i], text: w.text, icon: w.icon, wind: h.wind_speed_10m[i], dir: h.wind_direction_10m[i], gust: h.wind_gusts_10m[i], rh: h.relative_humidity_2m[i], dew: h.dew_point_2m[i], uv: h.uv_index[i], feels: h.apparent_temperature[i], src: 'Model' });
  }
  if (!nws) M.sources.push('Hourly: Open-Meteo best-match models');
  M.hours = hours;

  // ----- daily -----
  const nwsDay = new Map(), nwsNight = new Map();
  for (const p of nws?.forecast || []) (p.isDaytime ? nwsDay : nwsNight).set(p.startTime.slice(0, 10), p);
  M.days = d.time.map((t, i) => {
    const day = nwsDay.get(t);
    const prev = new Date(Date.UTC(+t.slice(0, 4), +t.slice(5, 7) - 1, +t.slice(8, 10) - 1)).toISOString().slice(0, 10);
    const night = nwsNight.get(prev);
    const w = wx(d.weather_code[i], 1);
    return {
      date: t, hi: day ? f2c(day.temperature) : d.temperature_2m_max[i], lo: night ? f2c(night.temperature) : d.temperature_2m_min[i],
      pop: day?.probabilityOfPrecipitation?.value ?? d.precipitation_probability_max[i] ?? 0,
      text: day?.shortForecast || w.text, icon: day ? nwsIcon(day.shortForecast, true) : w.icon,
      precip: d.precipitation_sum[i], uv: d.uv_index_max[i], wind: d.wind_speed_10m_max[i], gust: d.wind_gusts_10m_max[i], dir: d.wind_direction_10m_dominant[i],
      sunrise: d.sunrise[i], sunset: d.sunset[i], daylight: d.daylight_duration[i], src: day ? 'NWS' : 'Model',
      detail: day?.detailedForecast, nightDetail: nwsNight.get(t)?.detailedForecast,
    };
  });
  if (nws?.forecast) M.sources.push('Daily: NWS through day 7, model guidance after');

  // ----- next 2 hours (15 minute steps) -----
  if (D.minutely?.minutely_15) {
    const m = D.minutely.minutely_15;
    M.nowcast = m.time.map((t, i) => ({ time: t, mm: m.precipitation[i] ?? 0, code: m.weather_code?.[i] }));
  }
  M.aq = D.aq?.current || null;
  M.alerts = (nws?.alerts || []).map((f) => f.properties);
  return M;
}

// ================= renderers (return HTML strings) =================
export function heroHTML(M, loc) {
  const c = M.current, t = M.days[0];
  return `<div class="hero">
    <div class="hero-main">${icon(c.icon, 84)}<div><div class="hero-temp">${fmtT(c.temp)}</div><div class="hero-cond">${esc(c.text)}</div></div></div>
    <div class="hero-side">
      <div class="hero-loc">${esc(loc.name)}</div>
      <div>Feels like <b>${fmtT(c.feels)}</b></div>
      <div>High <b>${fmtT(t.hi)}</b> · Low <b>${fmtT(t.lo)}</b></div>
      <div>${compass(c.dir)} wind ${fmtW(c.wind)}${c.gust ? `, gusts ${fmtW(c.gust)}` : ''}</div>
      <div class="muted small">${c.observed ? `Measured at ${esc(c.observed.id)} · ${timeAgo(c.observed.time)}` : 'Model estimate'}</div>
    </div></div>`;
}

export function alertsHTML(M, compact = false) {
  if (!M.alerts?.length) return `<div class="empty ok">✓ No active alerts for this location${M.isUS ? '' : ' (alerts are US only)'}</div>`;
  return M.alerts.map((a, i) => `<button class="alert-card" data-alert="${i}" style="--ac:${alertColor(a.event)}">
    <b>${esc(a.event)}</b><span>${esc(compact ? '' : a.headline || '')}</span><small>Until ${a.ends || a.expires ? new Date(a.ends || a.expires).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' }) : 'further notice'}</small></button>`).join('');
}

export function nowcastHTML(M) {
  if (!M.nowcast) return '<div class="empty">Minute-by-minute data is not available here.</div>';
  const n = M.nowcast, max = Math.max(0.5, ...n.map((x) => x.mm));
  const firstWet = n.findIndex((x) => x.mm >= 0.1), wetNow = n[0]?.mm >= 0.1;
  const lastWet = wetNow ? n.findIndex((x) => x.mm < 0.1) : -1;
  let msg = 'No precipitation expected in the next 3 hours';
  if (wetNow) msg = lastWet > 0 ? `Precipitation ending in about ${lastWet * 15} min` : 'Precipitation continuing for the next few hours';
  else if (firstWet > 0) msg = `Precipitation starting in about ${firstWet * 15} min`;
  return `<div class="nc-msg">${msg}</div><div class="nc-bars">${n.map((x) => `<div title="${clockLabel(x.time)}: ${fmtP(x.mm)}"><i style="height:${clamp(x.mm / max * 100, x.mm > 0 ? 6 : 2, 100)}%"></i></div>`).join('')}</div>
  <div class="nc-axis"><span>Now</span><span>+1h</span><span>+2h</span><span>+3h</span></div>`;
}

export function hourlyHTML(M, count = 48) {
  const hs = M.hours.slice(0, count);
  const temps = hs.map((x) => U.temp(x.temp));
  const lo = Math.min(...temps), hi = Math.max(...temps), W = hs.length * 64, H = 120;
  const y = (v) => 18 + (1 - (v - lo) / Math.max(1, hi - lo)) * 58;
  const pts = temps.map((v, i) => `${i * 64 + 32},${y(v).toFixed(1)}`).join(' ');
  const svg = `<svg class="hr-chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
    ${hs.map((x, i) => `<rect x="${i * 64 + 14}" y="${H - x.pop * 0.3}" width="36" height="${x.pop * 0.3}" rx="3" class="pop-bar"/>`).join('')}
    <polyline points="${pts}" class="t-line"/>
    ${temps.map((v, i) => `<circle cx="${i * 64 + 32}" cy="${y(v).toFixed(1)}" r="3" class="t-dot"/><text x="${i * 64 + 32}" y="${(y(v) - 8).toFixed(1)}" class="t-lbl">${Math.round(v)}°</text>`).join('')}
  </svg>`;
  const cells = hs.map((x) => `<div class="hr-cell${x.time.slice(11, 13) === '00' ? ' midnight' : ''}">
    <div class="hr-time">${x.time.slice(11, 13) === '00' ? dayName(x.time) : hourLabel(x.time)}</div>${icon(x.icon, 30)}
    <div class="hr-pop">${x.pop >= 10 ? `${x.pop}%` : '&nbsp;'}</div>
    <div class="hr-wind"><i style="transform:rotate(${(x.dir ?? 0) + 180}deg)">↑</i>${x.wind != null ? Math.round(U.wind(x.wind)) : '--'}</div></div>`).join('');
  return `<div class="hr-scroll"><div class="hr-inner" style="width:${W}px">${svg}<div class="hr-cells">${cells}</div></div></div>
  <div class="legend-row"><span><i class="lg-line"></i>Temperature</span><span><i class="lg-bar"></i>Rain chance</span><span>Wind ${U.windU()}</span></div>`;
}

export function dailyHTML(M, count = 16) {
  const ds = M.days.slice(0, count);
  const lo = Math.min(...ds.map((x) => U.temp(x.lo))), hi = Math.max(...ds.map((x) => U.temp(x.hi)));
  const pct = (v) => ((U.temp(v) - lo) / Math.max(1, hi - lo)) * 100;
  return `<div class="daily">${ds.map((x, i) => `<details class="day-row">
    <summary><span class="d-name">${i === 0 ? 'Today' : dayName(x.date)}<small>${dateLabel(x.date)}</small></span>
      ${icon(x.icon, 34)}<span class="d-pop">${x.pop >= 10 ? `💧${x.pop}%` : ''}</span>
      <span class="d-lo">${fmtT(x.lo)}</span>
      <span class="d-bar"><i style="left:${pct(x.lo)}%;right:${100 - pct(x.hi)}%;background:linear-gradient(90deg,${tempColor(x.lo)},${tempColor(x.hi)})"></i></span>
      <span class="d-hi">${fmtT(x.hi)}</span>${x.src === 'Model' && M.isUS ? '<span class="tag" title="Beyond the NWS 7-day forecast">model</span>' : ''}</summary>
    <div class="day-detail">
      ${x.detail ? `<p><b>Day:</b> ${esc(x.detail)}</p>` : `<p>${esc(x.text)}</p>`}
      ${x.nightDetail ? `<p><b>Night:</b> ${esc(x.nightDetail)}</p>` : ''}
      <div class="kv-row"><span>Rain ${fmtP(x.precip)}</span><span>Wind ${compass(x.dir)} ${fmtW(x.wind)}</span><span>Gusts ${fmtW(x.gust)}</span><span>UV ${x.uv?.toFixed(0) ?? '--'}</span><span>Sunrise ${clockLabel(x.sunrise)}</span><span>Sunset ${clockLabel(x.sunset)}</span></div>
    </div></details>`).join('')}</div>`;
}

export function detailsHTML(M) {
  const c = M.current, uv = uvInfo(c.uv), d0 = M.days[0];
  const vis = U.vis(c.vis), pr = U.press(c.press);
  const capeTxt = c.cape == null ? '--' : c.cape < 300 ? 'Stable' : c.cape < 1000 ? 'Marginal' : c.cape < 2500 ? 'Unstable' : 'Very unstable';
  const items = [
    ['Wind', `${compass(c.dir)} ${fmtW(c.wind)}`, c.gust ? `Gusts ${fmtW(c.gust)}` : ''],
    ['Humidity', `${c.rh != null ? Math.round(c.rh) : '--'}%`, `Dew point ${fmtT(c.dew)}`],
    ['Pressure', pr != null ? `${pr.toFixed(U.pressU() === 'inHg' ? 2 : 0)} ${U.pressU()}` : '--', ''],
    ['Visibility', vis != null ? `${Math.min(vis, 10).toFixed(vis < 3 ? 1 : 0)}${vis >= 10 ? '+' : ''} ${U.visU()}` : '--', ''],
    ['UV Index', c.uv != null ? Math.round(c.uv) : '--', `<span style="color:${uv.color}">${uv.label}</span> · peak ${d0.uv?.toFixed(0) ?? '--'}`],
    ['Cloud Cover', `${c.cloud ?? '--'}%`, ''],
    ['Rain Today', fmtP(d0.precip), `${d0.pop}% chance`],
    ['Storm Energy', c.cape != null ? `${Math.round(c.cape)} J/kg` : '--', `CAPE · ${capeTxt}`],
  ];
  return `<div class="tiles">${items.map(([k, v, s]) => `<div class="tile"><div class="tile-k">${k}</div><div class="tile-v">${v}</div><div class="tile-s">${s}</div></div>`).join('')}</div>`;
}

export function aqHTML(M) {
  const a = M.aq; if (!a) return '<div class="empty">Air quality unavailable.</div>';
  const info = aqiInfo(a.us_aqi);
  const pol = [['PM2.5', a.pm2_5, 'µg/m³'], ['PM10', a.pm10, 'µg/m³'], ['Ozone', a.ozone, 'µg/m³'], ['NO₂', a.nitrogen_dioxide, 'µg/m³'], ['SO₂', a.sulphur_dioxide, 'µg/m³'], ['CO', a.carbon_monoxide, 'µg/m³']];
  return `<div class="aqi"><div class="aqi-num" style="--c:${info.color}">${a.us_aqi ?? '--'}</div><div><b>${info.label}</b><div class="muted small">US AQI</div></div></div>
    <div class="aqi-scale"><i style="left:${clamp((a.us_aqi || 0) / 300 * 100, 0, 100)}%"></i></div>
    <div class="kv-grid">${pol.map(([k, v, u]) => `<span>${k}</span><b>${v != null ? Math.round(v) : '--'} <small>${u}</small></b>`).join('')}</div>`;
}

export function sunHTML(M) {
  const d = M.days[0], mp = moonPhase();
  const dl = d.daylight ? `${Math.floor(d.daylight / 3600)}h ${Math.round(d.daylight % 3600 / 60)}m` : '--';
  const delta = M.days[1]?.daylight && d.daylight ? Math.round((M.days[1].daylight - d.daylight) / 60) : null;
  return `<div class="sun-row"><div><div class="tile-k">Sunrise</div><div class="tile-v">${clockLabel(d.sunrise)}</div></div><div><div class="tile-k">Sunset</div><div class="tile-v">${clockLabel(d.sunset)}</div></div></div>
    <div class="muted small">Daylight ${dl}${delta != null ? ` (${delta >= 0 ? '+' : ''}${delta} min tomorrow)` : ''}</div>
    <div class="moon"><span class="moon-ico" style="--p:${mp.illum}%"></span><div><b>${mp.name}</b><div class="muted small">${mp.illum}% illuminated · day ${mp.age}</div></div></div>`;
}

export function nwsTextHTML(M) {
  const ps = M.nws?.forecast;
  if (!ps) return '<div class="empty">The NWS text forecast covers US locations only.</div>';
  return `<div class="nws-text">${ps.slice(0, 14).map((p) => `<div class="nws-p"><b>${esc(p.name)}</b><span>${p.temperature}°F</span><p>${esc(p.detailedForecast)}</p></div>`).join('')}</div>`;
}

export function modelsHTML(models) {
  if (!models?.length) return '<div class="empty">Model data unavailable.</div>';
  const times = models[0].data.time, step = 3, W = 900, H = 260, pad = 36;
  const idx = times.map((_, i) => i).filter((i) => i % step === 0);
  const all = models.flatMap((m) => idx.map((i) => m.data.temperature_2m[i]).filter((v) => v != null).map(U.temp));
  const lo = Math.floor(Math.min(...all)), hi = Math.ceil(Math.max(...all));
  const X = (k) => pad + k / (idx.length - 1) * (W - pad - 10), Y = (v) => 14 + (1 - (v - lo) / Math.max(1, hi - lo)) * (H - 50);
  const days = idx.map((i, k) => (times[i].slice(11, 13) === '00' ? `<line x1="${X(k)}" x2="${X(k)}" y1="10" y2="${H - 30}" class="grid"/><text x="${X(k) + 4}" y="${H - 12}" class="axis">${dayName(times[i])}</text>` : '')).join('');
  const ticks = [lo, Math.round((lo + hi) / 2), hi].map((v) => `<text x="4" y="${Y(v) + 4}" class="axis">${v}°</text><line x1="${pad}" x2="${W - 10}" y1="${Y(v)}" y2="${Y(v)}" class="grid"/>`).join('');
  const lines = models.map((m) => { const p = idx.map((i, k) => (m.data.temperature_2m[i] == null ? null : `${X(k).toFixed(1)},${Y(U.temp(m.data.temperature_2m[i])).toFixed(1)}`)).filter(Boolean).join(' '); return `<polyline points="${p}" fill="none" stroke="${m.color}" stroke-width="2.2" stroke-linejoin="round"/>`; }).join('');
  const totals = models.map((m) => { const s = m.data.precipitation.reduce((a, b) => a + (b || 0), 0); return `<span><i style="background:${m.color}"></i>${esc(m.name)} <b>${fmtP(s)}</b></span>`; }).join('');
  return `<svg class="model-chart" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">${ticks}${days}${lines}</svg>
    <div class="model-legend">${totals}</div><div class="muted small">Lines show temperature from each model. Numbers are total rain each model expects over 7 days. When lines spread apart, forecast confidence is lower.</div>`;
}

export function afdHTML(afd) {
  if (!afd) return '<div class="empty">Forecast discussion unavailable (US only).</div>';
  return `<div class="muted small">Issued ${new Date(afd.issued).toLocaleString()}</div><pre class="afd">${esc(afd.text)}</pre>`;
}
