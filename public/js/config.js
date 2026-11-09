// Central settings. Change APP_NAME here to rename the whole site.
export const APP_NAME = 'Updraft';
export const APP_TAGLINE = 'Radar, forecasts and severe weather';

// Default location when the browser location is unavailable.
export const DEFAULT_LOC = { lat: 33.749, lon: -84.388, name: 'Atlanta, GA' };

// Hosts our Netlify proxy is allowed to fetch (must match netlify/functions/proxy.mts).
export const PROXY_PATH = '/api/proxy';

// Map tiles
// Esri basemaps (free, no key). Base and labels are separate so radar sits between them.
const ESRI = 'https://services.arcgisonline.com/ArcGIS/rest/services';
export const TILES = {
  dark: `${ESRI}/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}`,
  darkLabels: `${ESRI}/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}`,
  light: `${ESRI}/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}`,
  lightLabels: `${ESRI}/Canvas/World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}`,
  satellite: `${ESRI}/World_Imagery/MapServer/tile/{z}/{y}/{x}`,
  roads: `${ESRI}/World_Street_Map/MapServer/tile/{z}/{y}/{x}`,
  maxNative: 16,
};

// NWS warning colors (official NWS hazard map palette, most common events)
export const ALERT_COLORS = {
  'Tornado Warning': '#ff0000', 'Tornado Emergency': '#8b0000', 'Severe Thunderstorm Warning': '#ffa500',
  'Flash Flood Warning': '#8b0000', 'Flash Flood Emergency': '#8b0000', 'Flood Warning': '#00ff00',
  'Flood Advisory': '#00ff7f', 'Flood Watch': '#2e8b57', 'Flash Flood Watch': '#2e8b57',
  'Tornado Watch': '#ffff00', 'Severe Thunderstorm Watch': '#db7093', 'Special Weather Statement': '#ffe4b5',
  'Special Marine Warning': '#ffa500', 'Hurricane Warning': '#dc143c', 'Hurricane Watch': '#ff00ff',
  'Tropical Storm Warning': '#b22222', 'Tropical Storm Watch': '#f08080', 'Storm Surge Warning': '#b524f7',
  'Storm Surge Watch': '#db7ff7', 'Winter Storm Warning': '#ff69b4', 'Winter Storm Watch': '#4682b4',
  'Winter Weather Advisory': '#7b68ee', 'Ice Storm Warning': '#8b008b', 'Blizzard Warning': '#ff4500',
  'High Wind Warning': '#daa520', 'Wind Advisory': '#d2b48c', 'Extreme Heat Warning': '#c71585',
  'Heat Advisory': '#ff7f50', 'Extreme Cold Warning': '#0000ff', 'Cold Weather Advisory': '#afeeee',
  'Freeze Warning': '#483d8b', 'Frost Advisory': '#6495ed', 'Red Flag Warning': '#ff1493',
  'Fire Weather Watch': '#ffdead', 'Dense Fog Advisory': '#708090', 'Gale Warning': '#dda0dd',
  'Small Craft Advisory': '#d8bfd8', 'Rip Current Statement': '#40e0d0', 'High Surf Advisory': '#ba55d3',
  'Coastal Flood Warning': '#228b22', 'Coastal Flood Advisory': '#7cfc00', 'Air Quality Alert': '#808080',
  'Hazardous Weather Outlook': '#eee8aa',
};
export const alertColor = (ev) => ALERT_COLORS[ev] || '#9aa6b2';

// NEXRAD reflectivity legend (IEM N0Q palette, approximate)
export const DBZ_LEGEND = ['#04e9e7', '#019ff4', '#0300f4', '#02fd02', '#01c501', '#008e00', '#fdf802', '#e5bc00', '#fd9500', '#fd0000', '#d40000', '#bc0000', '#f800fd', '#9854c6'];

// Open-Meteo model ids used for the model comparison chart.
export const MODELS = [
  { id: 'ncep_nbm_conus', name: 'NBM (NWS blend)', color: '#38bdf8', us: true },
  { id: 'gfs_hrrr', name: 'HRRR', color: '#f472b6', us: true },
  { id: 'gfs_seamless', name: 'GFS', color: '#f59e0b' },
  { id: 'ecmwf_ifs025', name: 'ECMWF', color: '#22c55e' },
  { id: 'icon_seamless', name: 'ICON (German)', color: '#a78bfa' },
  { id: 'gem_seamless', name: 'GEM (Canadian)', color: '#ef4444' },
];

// ---------- keys and money ----------
// Free API keys. These are visible in the browser, so restrict each key to weather.dialcheck.io in the provider's dashboard.
export const KEYS = {
  tomtom: '',          // Traffic layer. Free key at developer.tomtom.com (50,000 map tiles a day free).
  nrel: 'DEMO_KEY',    // EV chargers (US DOE AFDC). DEMO_KEY is rate limited; get a free key at developer.nrel.gov/signup.
};
// Google AdSense. Leave client blank to show house ads ("Go ad-free") in every slot.
export const ADS = { client: '', slots: { banner: '', box: '', tall: '', inline: '' } };
// Stripe Payment Links for each paid plan (create them in the Stripe dashboard).
export const CHECKOUT = { plus: '', pro: '' };
