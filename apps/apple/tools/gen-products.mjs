import fs from 'fs';
const src = fs.readFileSync('public/js/dashboard.js', 'utf8');
const a = src.indexOf("const NESDIS = ");
const b = src.indexOf("export const TEMPLATES");
const c = src.indexOf("\n};", b) + 3;
let code = src.slice(a, c).replace(/export const /g, 'const ');
code += "\nreturn { WIDGETS, TEMPLATES };";
const { WIDGETS, TEMPLATES } = new Function(code)();
const rename = { sun: 'sdo_sun' };
const local = { now: 'now', alerts: 'alerts', nowcast: 'nowcast', hourly: 'hourly', daily: 'daily', details: 'details', minimap: 'radar', doppler: 'nwsloop', nwsloop: 'nwsloop', site_loop: 'nwsloop', aqi: 'aqi', nwstext: 'nwstext', afd: 'afd', models: 'models', storms: 'storms', spaghetti: 'spaghetti', models_links: 'models_links', scales: 'scales', marine: 'buoycam', links: 'links' };
const q = (s) => JSON.stringify(s);
const cats = [];
const byCat = {};
for (const [id0, w] of Object.entries(WIDGETS)) {
  if (w.kind !== 'image') continue;
  const id = rename[id0] || id0;
  if (!byCat[w.cat]) { byCat[w.cat] = []; cats.push(w.cat); }
  byCat[w.cat].push(`            .init(id: ${q(id)}, title: ${q(w.title)}, url: ${q(w.src)}, link: ${q(w.link)}${w.pro ? ', pro: true' : ''}),`);
}
const order = ['Radar & Satellite', 'Radar Loops', 'Satellite Sectors', 'Severe Weather', 'Tropics', 'Rain & Fronts', 'Winter Weather', 'Long Range', 'Marine & Space'];
cats.sort((x, y) => { const r = (c) => { const i = order.indexOf(c); return i < 0 ? 100 + cats.indexOf(c) : i; }; return r(x) - r(y); });
let out = `// Generated from public/js/dashboard.js (WIDGETS and TEMPLATES) so the app has the same maps and pages as the website.\n// Regenerate with: node apps/apple/tools/gen-products.mjs\n\nextension Products {\n    static let sections: [ProductSection] = [\n`;
for (const cat of cats) out += `        .init(id: ${q(cat)}, products: [\n${byCat[cat].join('\n')}\n        ]),\n`;
out += `    ]\n\n    /// The website's ready-made dashboard pages.\n    static let templates: [(name: String, pro: Bool, widgets: [(String, DashWidget.Size)])] = [\n`;
const sz = { s: '.small', m: '.medium', l: '.large', xl: '.large' };
for (const t of Object.values(TEMPLATES)) {
  const ws = t.w.map(([k, s]) => {
    if (local[k]) return `(${q(local[k])}, ${sz[s]})`;
    const w = WIDGETS[k]; if (!w || w.kind !== 'image') return null;
    return `(${q(rename[k] || k)}, ${sz[s]})`;
  }).filter(Boolean).filter((x, i, arr) => arr.findIndex((y) => y.split(',')[0] === x.split(',')[0]) === i);
  out += `        (${q(t.name)}, ${!!t.pro}, [${ws.join(', ')}]),\n`;
}
out += `    ]\n}\n`;
fs.writeFileSync('apps/apple/Shared/Pro/ProductsGenerated.swift', out);
console.log(cats.length, 'sections', Object.values(byCat).flat().length, 'maps', Object.keys(TEMPLATES).length, 'pages');
