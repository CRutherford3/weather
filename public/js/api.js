// All data fetching lives here. Every source is free and needs no API key.
import { getData, NWS_HEADERS } from './util.js';
import { MODELS } from './config.js';

const OM = 'https://api.open-meteo.com/v1/forecast';
const r4 = (n) => Number(n).toFixed(4);

// ---------- location search ----------
export async function geocode(q) {
  const j = await getData(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(q)}&count=8&language=en&format=json`);
  return (j.results || []).map((r) => ({
    lat: r.latitude, lon: r.longitude,
    name: [r.name, r.admin1 && r.country_code === 'US' ? stateAbbr(r.admin1) : r.admin1, r.country_code !== 'US' ? r.country : null].filter(Boolean).join(', '),
  }));
}
export async function reverseGeocode(lat, lon) {
  try {
    const j = await getData(`https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${lat}&longitude=${lon}&localityLanguage=en`, { noProxy: true });
    const city = j.city || j.locality || j.principalSubdivision;
    const st = j.countryCode === 'US' ? (j.principalSubdivisionCode || '').replace('US-', '') : j.countryName;
    return [city, st].filter(Boolean).join(', ') || `${lat.toFixed(2)}, ${lon.toFixed(2)}`;
  } catch { return `${lat.toFixed(2)}, ${lon.toFixed(2)}`; }
}

// ---------- point forecast bundle ----------
export async function loadPoint(loc) {
  const { lat, lon } = loc;
  const omUrl = `${OM}?latitude=${r4(lat)}&longitude=${r4(lon)}&timezone=auto&forecast_days=16`
    + '&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,dew_point_2m,visibility,uv_index,cape'
    + '&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,relative_humidity_2m,dew_point_2m,uv_index,is_day,cloud_cover,visibility,cape'
    + '&daily=weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,sunrise,sunset,daylight_duration,uv_index_max,precipitation_sum,precipitation_probability_max,precipitation_hours,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant';
  const minUrl = `${OM}?latitude=${r4(lat)}&longitude=${r4(lon)}&timezone=auto&minutely_15=precipitation,weather_code&forecast_minutely_15=12&past_minutely_15=0`;
  const aqUrl = `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${r4(lat)}&longitude=${r4(lon)}&timezone=auto&current=us_aqi,pm2_5,pm10,ozone,nitrogen_dioxide,carbon_monoxide,sulphur_dioxide&hourly=us_aqi&forecast_days=2`;

  const [om, minutely, aq, nws] = await Promise.allSettled([
    getData(omUrl), getData(minUrl), getData(aqUrl), loadNWS(lat, lon),
  ]);
  if (om.status !== 'fulfilled') throw new Error('Forecast service unavailable');
  return {
    om: om.value,
    minutely: minutely.status === 'fulfilled' ? minutely.value : null,
    aq: aq.status === 'fulfilled' ? aq.value : null,
    nws: nws.status === 'fulfilled' ? nws.value : null,
    fetched: Date.now(),
  };
}

// National Weather Service (US only): official forecast, nearest station observation, alerts, forecast discussion.
async function loadNWS(lat, lon) {
  const point = await getData(`https://api.weather.gov/points/${r4(lat)},${r4(lon)}`, { headers: NWS_HEADERS, cache: 3600e3 });
  const p = point.properties;
  const [fc, hourly, stations, alerts] = await Promise.allSettled([
    getData(p.forecast, { headers: NWS_HEADERS }),
    getData(p.forecastHourly, { headers: NWS_HEADERS }),
    getData(p.observationStations, { headers: NWS_HEADERS, cache: 86400e3 }),
    getData(`https://api.weather.gov/alerts/active?point=${r4(lat)},${r4(lon)}`, { headers: NWS_HEADERS }),
  ]);
  let obs = null, station = null;
  if (stations.status === 'fulfilled') {
    // Try the 3 nearest stations until one has a recent temperature reading
    for (const f of stations.value.features.slice(0, 3)) {
      try {
        const o = await getData(`${f.id}/observations/latest`, { headers: NWS_HEADERS });
        const age = Date.now() - new Date(o.properties.timestamp);
        if (o.properties.temperature?.value != null && age < 2 * 3600e3) { obs = o.properties; station = f.properties; break; }
      } catch { /* next station */ }
    }
  }
  return {
    office: p.cwa, radar: p.radarStation, city: p.relativeLocation?.properties,
    forecast: fc.status === 'fulfilled' ? fc.value.properties.periods : null,
    hourly: hourly.status === 'fulfilled' ? hourly.value.properties.periods : null,
    alerts: alerts.status === 'fulfilled' ? alerts.value.features : [],
    obs, station,
  };
}

export async function loadDiscussion(office) {
  const list = await getData(`https://api.weather.gov/products/types/AFD/locations/${office}`, { headers: { Accept: 'application/ld+json' } });
  const id = list['@graph']?.[0]?.['@id'];
  if (!id) return null;
  const p = await getData(id, { headers: { Accept: 'application/ld+json' } });
  return { text: p.productText, issued: p.issuanceTime };
}

// Run each model separately so one unavailable model never breaks the others.
export async function loadModels(loc) {
  const us = loc.lat > 20 && loc.lat < 55 && loc.lon > -130 && loc.lon < -60;
  const list = MODELS.filter((m) => us || !m.us);
  const res = await Promise.allSettled(list.map((m) => getData(`${OM}?latitude=${r4(loc.lat)}&longitude=${r4(loc.lon)}&timezone=auto&forecast_days=7&hourly=temperature_2m,precipitation&models=${m.id}`, { cache: 1800e3 })));
  return list.map((m, i) => ({ ...m, data: res[i].status === 'fulfilled' ? res[i].value.hourly : null })).filter((m) => m.data);
}

// Point lookup for map taps
export async function quickPoint(lat, lon) {
  return getData(`${OM}?latitude=${r4(lat)}&longitude=${r4(lon)}&timezone=auto&forecast_days=2&current=temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m,relative_humidity_2m&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max`);
}

// Light forecast for the radar card at the map crosshair: now, next 24 hours, next 3 days
export async function cardPoint(lat, lon) {
  return getData(`${OM}?latitude=${r4(lat)}&longitude=${r4(lon)}&timezone=auto&forecast_days=3&forecast_hours=25&current=temperature_2m,weather_code,is_day&hourly=temperature_2m&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code`, { cache: 600e3 });
}

// Grid of current conditions for the map temperature / wind layer
export async function gridPoints(lats, lons) {
  const j = await getData(`${OM}?latitude=${lats.join(',')}&longitude=${lons.join(',')}&current=temperature_2m,wind_speed_10m,wind_direction_10m,weather_code,is_day`);
  return Array.isArray(j) ? j : [j];
}

// ---------- national / map feeds ----------
export const feeds = {
  alerts: () => getData('https://api.weather.gov/alerts/active?status=actual', { headers: NWS_HEADERS, timeout: 30000, cache: 60e3 }),
  lsr: () => getData('https://mesonet.agron.iastate.edu/geojson/lsr.geojson?hours=24', { cache: 300e3 }),
  spc: (day = 1) => getData(`https://www.spc.noaa.gov/products/outlook/day${day}otlk_cat.lyr.geojson`, { proxyFirst: true, cache: 900e3 }),
  storms: () => getData('https://www.nhc.noaa.gov/CurrentStorms.json', { proxyFirst: true, cache: 600e3 }),
  quakes: () => getData('https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson', { cache: 300e3 }),
  fires: () => getData('https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query?where=IncidentSize%3E%3D100&outFields=IncidentName,IncidentSize,PercentContained,FireDiscoveryDateTime,POOState&f=geojson', { cache: 900e3 }),
  iemTms: () => getData('https://mesonet.agron.iastate.edu/json/tms.json', { cache: 120e3 }),
  rainviewer: () => getData('https://api.rainviewer.com/public/weather-maps.json', { cache: 120e3 }),
  // WPC coded surface fronts and pressure centers (plain text, parsed in map.js)
  fronts: () => getData('https://www.wpc.ncep.noaa.gov/basicwx/coded_srp.txt', { type: 'text', proxyFirst: true, cache: 900e3 }),
  // Active SPC mesoscale discussions with polygons
  mcd: () => getData('https://mesonet.agron.iastate.edu/api/1/nws/spc_mcd.geojson', { cache: 300e3 }),
  // US Drought Monitor, simplified shapes (about 250 KB)
  drought: () => getData('https://services5.arcgis.com/0OTVzJS4K09zlixn/arcgis/rest/services/USDM_current/FeatureServer/0/query?where=1%3D1&outFields=dm&maxAllowableOffset=0.05&geometryPrecision=3&f=geojson', { cache: 3600e3 }),
  // NHC GIS service: forecast cones and tracks
  nhcMeta: () => getData(`${NHC_GIS}?f=json`, { cache: 3600e3 }),
  nhcLayer: (id) => getData(`${NHC_GIS}/${id}/query?where=1%3D1&outFields=*&f=geojson`, { cache: 600e3 }),
  iss: () => getData('https://api.wheretheiss.at/v1/satellites/25544', { noProxy: true }),
  issPath: (ts) => getData(`https://api.wheretheiss.at/v1/satellites/25544/positions?timestamps=${ts.join(',')}`, { noProxy: true }),
};
const NHC_GIS = 'https://mapservices.weather.noaa.gov/tropical/rest/services/tropical/NHC_tropical_weather/MapServer';

// Air quality across a grid of points
export async function aqGrid(lats, lons) {
  const j = await getData(`https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lats.join(',')}&longitude=${lons.join(',')}&current=us_aqi`);
  return Array.isArray(j) ? j : [j];
}
// Current temperature for a list of saved places (one request)
export async function placesNow(list) {
  if (!list.length) return [];
  const j = await getData(`${OM}?latitude=${list.map((p) => r4(p.lat)).join(',')}&longitude=${list.map((p) => r4(p.lon)).join(',')}&current=temperature_2m,weather_code,is_day&timezone=auto`);
  return Array.isArray(j) ? j : [j];
}

const STATES = { Alabama: 'AL', Alaska: 'AK', Arizona: 'AZ', Arkansas: 'AR', California: 'CA', Colorado: 'CO', Connecticut: 'CT', Delaware: 'DE', Florida: 'FL', Georgia: 'GA', Hawaii: 'HI', Idaho: 'ID', Illinois: 'IL', Indiana: 'IN', Iowa: 'IA', Kansas: 'KS', Kentucky: 'KY', Louisiana: 'LA', Maine: 'ME', Maryland: 'MD', Massachusetts: 'MA', Michigan: 'MI', Minnesota: 'MN', Mississippi: 'MS', Missouri: 'MO', Montana: 'MT', Nebraska: 'NE', Nevada: 'NV', 'New Hampshire': 'NH', 'New Jersey': 'NJ', 'New Mexico': 'NM', 'New York': 'NY', 'North Carolina': 'NC', 'North Dakota': 'ND', Ohio: 'OH', Oklahoma: 'OK', Oregon: 'OR', Pennsylvania: 'PA', 'Rhode Island': 'RI', 'South Carolina': 'SC', 'South Dakota': 'SD', Tennessee: 'TN', Texas: 'TX', Utah: 'UT', Vermont: 'VT', Virginia: 'VA', Washington: 'WA', 'West Virginia': 'WV', Wisconsin: 'WI', Wyoming: 'WY', 'District of Columbia': 'DC', 'Puerto Rico': 'PR' };
const stateAbbr = (s) => STATES[s] || s;
