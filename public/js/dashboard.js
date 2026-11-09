// Customizable dashboard: widgets can be added, removed, resized and dragged into any order. Saved per browser.
import { store, esc, $, $$, toast, getData } from './util.js';
import { radarSites } from './api.js';
import * as F from './forecast.js';
import { TILES } from './config.js';
import { adSlot, fillAds, has, plan as curPlan, PAGE_LIMIT, openPricing } from './plan.js';

const L = window.L;
const NESDIS = 'https://cdn.star.nesdis.noaa.gov/GOES19/ABI';
const NESDIS_W = 'https://cdn.star.nesdis.noaa.gov/GOES18/ABI';
const SPC = 'https://www.spc.noaa.gov';
const WPC = 'https://www.wpc.ncep.noaa.gov';
const CIMSS = 'https://tropic.ssec.wisc.edu/real-time/atlantic/winds';
const TT = 'https://www.tropicaltidbits.com/analysis/ocean';
const MESO = (p, t) => IMG(`Mesoanalysis: ${t}`, 'Severe Weather', `${SPC}/exper/mesoanalysis/s19/${p}/${p}.gif`, 'https://www.spc.noaa.gov/exper/mesoanalysis/', 30);
const SEC = (sat, sec, t, cat = 'Satellite Sectors') => IMG(t, cat, `${sat === 18 ? NESDIS_W : NESDIS}/SECTOR/${sec}/GEOCOLOR/1200x1200.jpg`, `https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G${sat}&sector=${sec}`, 10);
const RIDGE = (k, t) => IMG(`${t} Radar Loop`, 'Radar Loops', `https://radar.weather.gov/ridge/standard/${k}_loop.gif`, 'https://radar.weather.gov/', 5);

// Image products (NOAA/NWS, public domain). refresh = minutes between reloads.
const IMG = (title, cat, src, link, refresh = 15, note = '') => ({ title, cat, kind: 'image', src, link, refresh, note });
export const WIDGETS = {
  // ---- local, live data ----
  now: { title: 'Current Conditions', cat: 'Your Location', size: 'm', kind: 'local' },
  alerts: { title: 'Alerts', cat: 'Your Location', size: 'm', kind: 'local' },
  nowcast: { title: 'Next 3 Hours', cat: 'Your Location', size: 'm', kind: 'local' },
  hourly: { title: 'Hourly Forecast', cat: 'Your Location', size: 'xl', kind: 'local' },
  daily: { title: '16-Day Forecast', cat: 'Your Location', size: 'l', kind: 'local' },
  details: { title: 'Conditions Detail', cat: 'Your Location', size: 'l', kind: 'local' },
  minimap: { title: 'Live Radar', cat: 'Your Location', size: 'l', kind: 'local' },
  nwsloop: { title: 'Local NWS Radar Loop', cat: 'Your Location', size: 'm', kind: 'local' },
  site_loop: { title: 'Radar Site Loop (Pro)', cat: 'Radar Loops', size: 'm', kind: 'local' },
  aqi: { title: 'Air Quality', cat: 'Your Location', size: 's', kind: 'local' },
  sun: { title: 'Sun & Moon', cat: 'Your Location', size: 's', kind: 'local' },
  nwstext: { title: 'NWS Forecast Text', cat: 'Your Location', size: 'l', kind: 'local' },
  models: { title: 'Model Comparison', cat: 'Your Location', size: 'xl', kind: 'local' },
  afd: { title: 'Forecast Discussion', cat: 'Your Location', size: 'xl', kind: 'local' },
  // ---- tropics ----
  storms: { title: 'Active Tropical Systems', cat: 'Tropics', size: 'l', kind: 'local' },
  nhc_atl7: IMG('Atlantic 7-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=atlc&fdays=7', 30),
  nhc_atl2: IMG('Atlantic 2-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_atl_2d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=atlc&fdays=2', 30),
  nhc_epac7: IMG('East Pacific 7-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_pac_7d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=epac&fdays=7', 30),
  goes_taw: IMG('Tropical Atlantic Satellite', 'Tropics', `${NESDIS}/SECTOR/taw/GEOCOLOR/900x540.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=taw', 10),
  goes_gm: IMG('Gulf Satellite Loop', 'Tropics', `${NESDIS}/SECTOR/gm/GEOCOLOR/GOES19-GM-GEOCOLOR-1000x1000.gif`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=gm', 10),
  goes_car: IMG('Caribbean Satellite', 'Tropics', `${NESDIS}/SECTOR/car/GEOCOLOR/1000x1000.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=car', 10),
  // ---- severe ----
  spc_d1: IMG('SPC Day 1 Severe Outlook', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody1.png', 'https://www.spc.noaa.gov/products/outlook/day1otlk.html', 15),
  spc_d2: IMG('SPC Day 2 Severe Outlook', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody2.png', 'https://www.spc.noaa.gov/products/outlook/day2otlk.html', 30),
  spc_d3: IMG('SPC Day 3 Severe Outlook', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody3.png', 'https://www.spc.noaa.gov/products/outlook/day3otlk.html', 60),
  spc_torn: IMG('SPC Day 1 Tornado Risk', 'Severe Weather', 'https://www.spc.noaa.gov/partners/outlooks/national/swody1_TORN.png', 'https://www.spc.noaa.gov/products/outlook/day1probotlk.html', 15),
  spc_ww: IMG('Active Watches', 'Severe Weather', 'https://www.spc.noaa.gov/products/watch/validww.png', 'https://www.spc.noaa.gov/products/watch/', 5),
  spc_md: IMG('Mesoscale Discussions', 'Severe Weather', 'https://www.spc.noaa.gov/products/md/validmd.png', 'https://www.spc.noaa.gov/products/md/', 5),
  // ---- radar & satellite ----
  radar_conus: IMG('US Radar Loop', 'Radar & Satellite', 'https://radar.weather.gov/ridge/standard/CONUS-LARGE_loop.gif', 'https://radar.weather.gov/', 5),
  radar_se: IMG('Southeast Radar Loop', 'Radar & Satellite', 'https://radar.weather.gov/ridge/standard/SOUTHEAST_loop.gif', 'https://radar.weather.gov/', 5),
  goes_conus: IMG('US Satellite (GeoColor)', 'Radar & Satellite', `${NESDIS}/CONUS/GEOCOLOR/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_conus_loop: IMG('US Satellite Loop', 'Radar & Satellite', `${NESDIS}/CONUS/GEOCOLOR/GOES19-CONUS-GEOCOLOR-625x375.gif`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_se: IMG('Southeast Satellite', 'Radar & Satellite', `${NESDIS}/SECTOR/se/GEOCOLOR/1200x1200.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=se', 10),
  goes_se_loop: IMG('Southeast Satellite Loop', 'Radar & Satellite', `${NESDIS}/SECTOR/se/GEOCOLOR/GOES19-SE-GEOCOLOR-600x600.gif`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=se', 10),
  goes_wv: IMG('US Water Vapor', 'Radar & Satellite', `${NESDIS}/CONUS/09/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  // ---- rain & fronts ----
  wpc_sfc: IMG('Surface Analysis (Fronts)', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/sfc/namussfcwbg.gif', 'https://www.wpc.ncep.noaa.gov/html/sfc-zoom.php', 60),
  wpc_d1: IMG('Fronts: Tomorrow', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/basicwx/92fwbg.gif', 'https://www.wpc.ncep.noaa.gov/basicwx/basicwx_ndfd.php', 120),
  wpc_qpf1: IMG('Rain Forecast: Day 1', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/qpf/fill_94qwbg.gif', 'https://www.wpc.ncep.noaa.gov/qpf/qpf2.shtml', 120),
  wpc_qpf7: IMG('Rain Forecast: 7 Days', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/qpf/p168i.gif', 'https://www.wpc.ncep.noaa.gov/qpf/qpf2.shtml', 120),
  wpc_ero: IMG('Flash Flood Risk: Day 1', 'Rain & Fronts', 'https://www.wpc.ncep.noaa.gov/qpf/94ewbg.gif', 'https://www.wpc.ncep.noaa.gov/qpf/excessive_rainfall_outlook_ero.php', 120),
  // ---- outlooks ----
  cpc_610t: IMG('6-10 Day Temperature Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/610temp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/', 360),
  cpc_610p: IMG('6-10 Day Rain Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/610prcp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/610day/', 360),
  cpc_814t: IMG('8-14 Day Temperature Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/814temp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/', 360),
  cpc_814p: IMG('8-14 Day Rain Outlook', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/814prcp.new.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/814day/', 360),
  // ---- tropics, spaghettimodels-style ----
  spaghetti: { title: 'Spaghetti Models', cat: 'Tropics', size: 'xl', kind: 'local' },
  models_links: { title: 'Model Shortcuts', cat: 'Tropics', size: 'm', kind: 'local' },
  nhc_epac2: IMG('East Pacific 2-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_pac_2d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=epac&fdays=2', 30),
  nhc_cpac7: IMG('Central Pacific 7-Day Outlook', 'Tropics', 'https://www.nhc.noaa.gov/xgtwo/two_cpac_7d0.png', 'https://www.nhc.noaa.gov/gtwo.php?basin=cpac&fdays=7', 30),
  goes_taw_loop: IMG('Tropical Atlantic Loop', 'Tropics', `${NESDIS}/SECTOR/taw/GEOCOLOR/GOES19-TAW-GEOCOLOR-900x540.gif`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=taw', 10),
  goes_car_loop: IMG('Caribbean Loop', 'Tropics', `${NESDIS}/SECTOR/car/GEOCOLOR/GOES19-CAR-GEOCOLOR-1000x1000.gif`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=car', 10),
  goes_pr: IMG('Puerto Rico Satellite', 'Tropics', `${NESDIS}/SECTOR/pr/GEOCOLOR/1200x1200.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/sector.php?sat=G19&sector=pr', 10),
  goes_fd: IMG('Full Disk (Western Hemisphere)', 'Tropics', `${NESDIS}/FD/GEOCOLOR/1808x1808.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/fulldisk.php?sat=G19', 10),
  cimss_shear: IMG('Wind Shear (CIMSS)', 'Tropics', `${CIMSS}/wg8shr.GIF`, 'https://tropic.ssec.wisc.edu/', 60),
  cimss_steer: IMG('Steering Currents (CIMSS)', 'Tropics', `${CIMSS}/wg8dlm1.GIF`, 'https://tropic.ssec.wisc.edu/', 60),
  cimss_vort: IMG('850mb Vorticity (CIMSS)', 'Tropics', `${CIMSS}/wg8vor3.GIF`, 'https://tropic.ssec.wisc.edu/', 60),
  cimss_sal: IMG('Saharan Air Layer (CIMSS)', 'Tropics', 'https://tropic.ssec.wisc.edu/real-time/sal/splitEW.jpg', 'https://tropic.ssec.wisc.edu/', 60),
  sst_atl: IMG('Atlantic Sea Temps', 'Tropics', `${TT}/cdas-sflux_sst_atl_1.png`, 'https://www.tropicaltidbits.com/analysis/ocean/', 360),
  ssta_atl: IMG('Atlantic Sea Temp Anomaly', 'Tropics', `${TT}/cdas-sflux_ssta_atl_1.png`, 'https://www.tropicaltidbits.com/analysis/ocean/', 360),
  ssta_glob: IMG('Global Sea Temp Anomaly', 'Tropics', `${TT}/cdas-sflux_ssta_global_1.png`, 'https://www.tropicaltidbits.com/analysis/ocean/', 360),
  scales: { title: 'Reference Scales', cat: 'Tropics', size: 'l', kind: 'local' },
  // ---- more severe ----
  spc_hail: IMG('SPC Day 1 Hail Risk', 'Severe Weather', `${SPC}/partners/outlooks/national/swody1_HAIL.png`, `${SPC}/products/outlook/day1probotlk.html`, 15),
  spc_wind: IMG('SPC Day 1 Wind Risk', 'Severe Weather', `${SPC}/partners/outlooks/national/swody1_WIND.png`, `${SPC}/products/outlook/day1probotlk.html`, 15),
  spc_d48: IMG('SPC Days 4-8 Outlook', 'Severe Weather', `${SPC}/products/exper/day4-8/day48prob.gif`, `${SPC}/products/exper/day4-8/`, 120),
  spc_rpt: IMG("Today's Storm Reports", 'Severe Weather', `${SPC}/climo/reports/today.gif`, `${SPC}/climo/reports/today.html`, 10),
  spc_rpty: IMG("Yesterday's Storm Reports", 'Severe Weather', `${SPC}/climo/reports/yesterday.gif`, `${SPC}/climo/reports/yesterday.html`, 120),
  spc_fire: IMG('Fire Weather Outlook', 'Severe Weather', `${SPC}/products/fire_wx/day1otlk_fire.gif`, `${SPC}/products/fire_wx/`, 60),
  nws_haz: IMG('NWS Hazards Map', 'Severe Weather', 'https://forecast.weather.gov/wwamap/png/US.png', 'https://www.weather.gov/', 10),
  meso_scp: MESO('scp', 'Supercell Composite'), meso_stp: MESO('stpc', 'Significant Tornado'), meso_cape: MESO('sbcp', 'Surface CAPE'), meso_shr: MESO('shr6', 'Deep Layer Shear'),
  hailhist: { title: 'Hail History Here', cat: 'Severe Weather', size: 'l', kind: 'local' },
  // ---- more satellite ----
  goes_ir: IMG('US Infrared', 'Radar & Satellite', `${NESDIS}/CONUS/13/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_vis: IMG('US Visible', 'Radar & Satellite', `${NESDIS}/CONUS/02/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_air: IMG('US Air Mass', 'Radar & Satellite', `${NESDIS}/CONUS/AirMass/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_sand: IMG('US Sandwich (storm tops)', 'Radar & Satellite', `${NESDIS}/CONUS/Sandwich/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_glm: IMG('US Lightning (GLM)', 'Radar & Satellite', 'https://cdn.star.nesdis.noaa.gov/GOES19/GLM/CONUS/EXTENT3/1250x750.jpg', 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 5),
  goes_glm_loop: IMG('US Lightning Loop', 'Radar & Satellite', 'https://cdn.star.nesdis.noaa.gov/GOES19/GLM/CONUS/EXTENT3/GOES19-CONUS-EXTENT3-625x375.gif', 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 5),
  goes_ir_loop: IMG('US Infrared Loop', 'Radar & Satellite', `${NESDIS}/CONUS/13/GOES19-CONUS-13-625x375.gif`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_wv_loop: IMG('US Water Vapor Loop', 'Radar & Satellite', `${NESDIS}/CONUS/08/GOES19-CONUS-08-625x375.gif`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  goes_fire: IMG('US Fire Temperature', 'Radar & Satellite', `${NESDIS}/CONUS/FireTemperature/1250x750.jpg`, 'https://www.star.nesdis.noaa.gov/GOES/conus.php?sat=G19', 10),
  sec_ne: SEC(19, 'ne', 'Northeast'), sec_cgl: SEC(19, 'cgl', 'Great Lakes'), sec_umv: SEC(19, 'umv', 'Upper Mississippi Valley'),
  sec_smv: SEC(19, 'smv', 'Southern Mississippi Valley'), sec_sp: SEC(19, 'sp', 'Southern Plains'),   sec_nr: SEC(19, 'nr', 'Northern Rockies'), sec_sr: SEC(19, 'sr', 'Southern Rockies'), sec_pnw: SEC(18, 'pnw', 'Pacific Northwest'), sec_psw: SEC(18, 'psw', 'Pacific Southwest'),
  sec_ak: SEC(18, 'cak', 'Alaska'), sec_hi: SEC(18, 'hi', 'Hawaii'),
  rl_ne: RIDGE('NORTHEAST', 'Northeast'), rl_cgl: RIDGE('CENTGRLAKES', 'Central Great Lakes'), rl_umv: RIDGE('UPPERMISSVLY', 'Upper Mississippi Valley'),
  rl_smv: RIDGE('SOUTHMISSVLY', 'Southern Mississippi Valley'), rl_sp: RIDGE('SOUTHPLAINS', 'Southern Plains'), rl_nr: RIDGE('NORTHROCKIES', 'Northern Rockies'), rl_sr: RIDGE('SOUTHROCKIES', 'Southern Rockies'),
  rl_pnw: RIDGE('PACNORTHWEST', 'Pacific Northwest'), rl_psw: RIDGE('PACSOUTHWEST', 'Pacific Southwest'), rl_ak: RIDGE('ALASKA', 'Alaska'), rl_hi: RIDGE('HAWAII', 'Hawaii'), rl_pr: RIDGE('CARIB', 'Puerto Rico'),
  // ---- more rain, fronts, winter ----
  ncfc1: IMG('National Forecast: Today', 'Rain & Fronts', `${WPC}/NationalForecastChart/staticmaps/noaad1.png`, `${WPC}/national_forecast/`, 120),
  ncfc2: IMG('National Forecast: Tomorrow', 'Rain & Fronts', `${WPC}/NationalForecastChart/staticmaps/noaad2.png`, `${WPC}/national_forecast/`, 120),
  ncfc3: IMG('National Forecast: Day 3', 'Rain & Fronts', `${WPC}/NationalForecastChart/staticmaps/noaad3.png`, `${WPC}/national_forecast/`, 120),
  wpc_qpf2: IMG('Rain Forecast: Day 2', 'Rain & Fronts', `${WPC}/qpf/fill_98qwbg.gif`, `${WPC}/qpf/qpf2.shtml`, 120),
  wpc_qpf3: IMG('Rain Forecast: Day 3', 'Rain & Fronts', `${WPC}/qpf/fill_99qwbg.gif`, `${WPC}/qpf/qpf2.shtml`, 120),
  wpc_qpf5: IMG('Rain Forecast: 5 Days', 'Rain & Fronts', `${WPC}/qpf/p120i.gif`, `${WPC}/qpf/qpf2.shtml`, 120),
  wpc_ero2: IMG('Flash Flood Risk: Day 2', 'Rain & Fronts', `${WPC}/qpf/98ewbg.gif`, `${WPC}/qpf/excessive_rainfall_outlook_ero.php`, 120),
  wpc_ero3: IMG('Flash Flood Risk: Day 3', 'Rain & Fronts', `${WPC}/qpf/99ewbg.gif`, `${WPC}/qpf/excessive_rainfall_outlook_ero.php`, 120),
  usdm: IMG('U.S. Drought Monitor', 'Long Range', 'https://droughtmonitor.unl.edu/data/png/current/current_usdm.png', 'https://droughtmonitor.unl.edu/', 720),
  cpc_34t: IMG('Weeks 3-4 Temperature', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/WK34/gifs/WK34temp.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/WK34/', 720),
  cpc_34p: IMG('Weeks 3-4 Rain', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/WK34/gifs/WK34prcp.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/WK34/', 720),
  cpc_30t: IMG('Next Month Temperature', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/30day/off15_temp.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/30day/', 720),
  cpc_30p: IMG('Next Month Rain', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/30day/off15_prcp.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/30day/', 720),
  cpc_90t: IMG('3-Month Temperature', 'Long Range', 'https://www.cpc.ncep.noaa.gov/products/predictions/90day/off01_temp.gif', 'https://www.cpc.ncep.noaa.gov/products/predictions/90day/', 720),
  // ---- marine & space ----
  opc_atl: IMG('Atlantic Surface Analysis', 'Marine & Space', 'https://ocean.weather.gov/A_sfc_full_ocean_color.png', 'https://ocean.weather.gov/', 180),
  opc_pac: IMG('Pacific Surface Analysis', 'Marine & Space', 'https://ocean.weather.gov/P_sfc_full_ocean_color.png', 'https://ocean.weather.gov/', 180),
  aurora_n: IMG('Aurora Forecast (North)', 'Marine & Space', 'https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg', 'https://www.swpc.noaa.gov/products/aurora-30-minute-forecast', 15),
  aurora_tn: IMG("Tonight's Aurora View Line", 'Marine & Space', 'https://services.swpc.noaa.gov/experimental/images/aurora_dashboard/tonights_static_viewline_forecast.png', 'https://www.swpc.noaa.gov/content/aurora-dashboard-experimental', 60),
  kp: IMG('Geomagnetic K Index', 'Marine & Space', 'https://services.swpc.noaa.gov/images/station-k-index.png', 'https://www.swpc.noaa.gov/products/planetary-k-index', 30),
  swx: IMG('Space Weather Overview', 'Marine & Space', 'https://services.swpc.noaa.gov/images/swx-overview-large.gif', 'https://www.swpc.noaa.gov/', 15),
  sun: IMG('The Sun Right Now (SDO)', 'Marine & Space', 'https://sdo.gsfc.nasa.gov/assets/img/latest/latest_1024_0193.jpg', 'https://sdo.gsfc.nasa.gov/data/', 30),
  marine_links: { title: 'Buoys, Tides & Rivers', cat: 'Marine & Space', size: 'm', kind: 'local' },
  // ---- links & custom ----
  links: { title: 'Weather Links', cat: 'Links & Custom', size: 'm', kind: 'local' },
  custom_image: { title: 'Custom Image or Loop', cat: 'Links & Custom', size: 'm', kind: 'custom' },
  custom_link: { title: 'Custom Link', cat: 'Links & Custom', size: 's', kind: 'custom' },
};

// Ready-made layouts (like the sections on spaghettimodels.com). Each can become its own dashboard page.
export const TEMPLATES = {
  mine: { name: 'My Weather', w: [['now', 'm'], ['alerts', 'm'], ['nowcast', 'm'], ['hourly', 'xl'], ['minimap', 'l'], ['daily', 'l'], ['nhc_atl7', 'm'], ['spc_d1', 'm'], ['goes_se_loop', 'm'], ['wpc_qpf7', 'm'], ['nwsloop', 'm'], ['links', 'm']] },
  tropics: { name: 'Tropics', pro: true, w: [['storms', 'l'], ['spaghetti', 'xl'], ['nhc_atl7', 'm'], ['nhc_atl2', 'm'], ['nhc_epac7', 'm'], ['goes_taw_loop', 'l'], ['goes_gm', 'm'], ['goes_car_loop', 'm'], ['goes_pr', 'm'], ['cimss_shear', 'm'], ['cimss_steer', 'm'], ['cimss_vort', 'm'], ['cimss_sal', 'm'], ['sst_atl', 'm'], ['ssta_atl', 'm'], ['ssta_glob', 'm'], ['opc_atl', 'm'], ['goes_fd', 'm'], ['models_links', 'm'], ['scales', 'l']] },
  severe: { name: 'Severe', pro: true, w: [['alerts', 'm'], ['spc_d1', 'm'], ['spc_torn', 'm'], ['spc_hail', 'm'], ['spc_wind', 'm'], ['spc_ww', 'm'], ['spc_md', 'm'], ['radar_conus', 'l'], ['site_loop', 'm'], ['goes_glm_loop', 'm'], ['meso_scp', 'm'], ['meso_stp', 'm'], ['meso_cape', 'm'], ['meso_shr', 'm'], ['spc_rpt', 'm'], ['spc_d2', 'm'], ['spc_d3', 'm'], ['spc_d48', 'm'], ['nws_haz', 'l'], ['hailhist', 'l'], ['scales', 'l']] },
  rain: { name: 'Rain & Winter', w: [['wpc_sfc', 'l'], ['ncfc1', 'm'], ['ncfc2', 'm'], ['ncfc3', 'm'], ['wpc_qpf1', 'm'], ['wpc_qpf2', 'm'], ['wpc_qpf3', 'm'], ['wpc_qpf5', 'm'], ['wpc_qpf7', 'm'], ['wpc_ero', 'm'], ['wpc_ero2', 'm'], ['wpc_ero3', 'm'], ['cpc_610t', 'm'], ['cpc_610p', 'm'], ['cpc_814t', 'm'], ['cpc_814p', 'm'], ['cpc_34t', 'm'], ['cpc_30t', 'm'], ['usdm', 'm']] },
  sat: { name: 'Satellite & Radar', w: [['goes_conus_loop', 'l'], ['radar_conus', 'l'], ['site_loop', 'm'], ['goes_ir', 'm'], ['goes_wv_loop', 'm'], ['goes_vis', 'm'], ['goes_air', 'm'], ['goes_sand', 'm'], ['goes_glm', 'm'], ['goes_fire', 'm'], ['sec_ne', 'm'], ['sec_sp', 'm'], ['sec_cgl', 'm'], ['sec_psw', 'm'], ['rl_ne', 'm'], ['rl_sp', 'm'], ['rl_psw', 'm'], ['radar_se', 'm']] },
  space: { name: 'Space & Marine', w: [['aurora_n', 'm'], ['aurora_tn', 'm'], ['kp', 'm'], ['swx', 'l'], ['sun', 'm'], ['opc_atl', 'l'], ['opc_pac', 'l'], ['marine_links', 'm']] },
};
const fromTpl = (k) => TEMPLATES[k].w.map(([type, size]) => ({ id: uid(), type, size }));
const DEFAULT_LAYOUT = fromTpl('mine');

function uid() { return Math.random().toString(36).slice(2, 9); }
// Pages: [{ id, name, layout }]. Migrates the old single layout.
let pages = store.get('dashPages', null) || [{ id: uid(), name: 'My Weather', layout: store.get('dash', null) || DEFAULT_LAYOUT }];
let cur = Math.min(store.get('dashPage', 0), pages.length - 1);
let layout = pages[cur].layout;
let editing = false, ctx = {}, sortable, miniMaps = [], refreshTimer;
const SIZES = ['s', 'm', 'l', 'xl'];
const save = () => { pages[cur].layout = layout; store.set('dashPages', pages); store.set('dashPage', cur); };
function goPage(i) { cur = i; layout = pages[cur].layout; save(); render(); }
function renderPages() {
  $('#dashPages').innerHTML = pages.map((p, i) => `<button class="dp${i === cur ? ' on' : ''}" data-pg="${i}">${esc(p.name)}${editing && pages.length > 1 && i === cur ? '<i data-pgdel title="Delete page">✕</i>' : ''}</button>`).join('') + '<button class="dp add" data-pgadd title="Add a page">+</button>';
}
function onPagesClick(e) {
  if (e.target.closest('[data-pgdel]')) { if (confirmInline2(e.target.closest('[data-pgdel]'))) { pages.splice(cur, 1); goPage(Math.max(0, cur - 1)); } return; }
  const b = e.target.closest('[data-pg]'); if (b) { if (+b.dataset.pg === cur && editing) return renamePage(); goPage(+b.dataset.pg); return; }
  if (e.target.closest('[data-pgadd]')) openLayouts();
}
function confirmInline2(el) { if (el.dataset.armed) return true; el.dataset.armed = 1; el.textContent = 'Delete?'; setTimeout(() => { delete el.dataset.armed; el.textContent = '✕'; }, 3000); return false; }
function renamePage() {
  window.dispatchEvent(new CustomEvent('modal', { detail: { title: 'Rename page', html: `<div class="custom-form"><label>Page name<input id="pgName" value="${esc(pages[cur].name)}" maxlength="24"></label><button class="btn" id="pgSave">Save</button></div>` } }));
  $('#pgSave').onclick = () => { pages[cur].name = $('#pgName').value.trim() || pages[cur].name; save(); renderPages(); window.dispatchEvent(new CustomEvent('modal-close')); };
}
function openLayouts() {
  const lim = PAGE_LIMIT[curPlan()];
  const html = `<p class="muted small">Pick a ready-made layout. Add it as a new page, or swap it into the page you're on.</p><div class="tpl-grid">${Object.entries(TEMPLATES).map(([k, t]) => `<div class="tpl"><b>${esc(t.name)}</b><small>${t.w.length} widgets</small><div class="tpl-btns"><button class="btn small" data-tadd="${k}">Add page</button><button class="btn small ghost" data-tset="${k}">Use here</button></div></div>`).join('')}</div>
    <p class="muted small">${pages.length}/${lim > 50 ? '∞' : lim} pages on your plan.</p>`;
  window.dispatchEvent(new CustomEvent('modal', { detail: { title: 'Dashboard layouts', html } }));
  $$('[data-tadd]').forEach((b) => b.onclick = () => {
    if (pages.length >= lim) { window.dispatchEvent(new CustomEvent('modal-close')); openPricing(`Your plan includes ${lim} dashboard page${lim > 1 ? 's' : ''}. Plus gets 5, Pro is unlimited.`); return; }
    const k = b.dataset.tadd; pages.push({ id: uid(), name: TEMPLATES[k].name, layout: fromTpl(k) });
    window.dispatchEvent(new CustomEvent('modal-close')); goPage(pages.length - 1);
  });
  $$('[data-tset]').forEach((b) => b.onclick = () => { const k = b.dataset.tset; layout = fromTpl(k); pages[cur].name = TEMPLATES[k].name; window.dispatchEvent(new CustomEvent('modal-close')); save(); render(); });
}

export function initDashboard() {
  $('#dashEdit').onclick = () => { editing = !editing; $('#dashEdit').textContent = editing ? 'Done' : 'Customize'; $('#dashboard').classList.toggle('editing', editing); $('#dashAdd').hidden = !editing; $('#dashReset').hidden = !editing; sortable?.option('disabled', !editing); renderPages(); };
  $('#dashAdd').onclick = openCatalog;
  $('#dashTpl').onclick = openLayouts;
  $('#dashPages').addEventListener('click', onPagesClick);
  window.addEventListener('plan', () => { if (!$('#view-dashboard').hidden) render(); });
  $('#dashReset').onclick = () => { if (confirmInline('#dashReset', 'Reset layout?')) { layout = fromTpl('mine'); save(); render(); } };
  $('#dashGrid').addEventListener('click', onGridClick);
  $('#dashGrid').addEventListener('change', onGridChange);
  if (window.Sortable) {
    sortable = window.Sortable.create($('#dashGrid'), { animation: 180, handle: '.w-head', draggable: '.widget', disabled: true, ghostClass: 'w-ghost',
      onEnd: () => { const order = $$('#dashGrid > .widget').map((e) => e.dataset.id); layout.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id)); save(); } });
  }
  clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshImages, 60e3);
}
// Two-click confirm without browser dialogs
function confirmInline(sel, label) {
  const b = $(sel); if (b.dataset.armed) { delete b.dataset.armed; b.textContent = 'Reset'; return true; }
  b.dataset.armed = 1; b.textContent = label; setTimeout(() => { delete b.dataset.armed; b.textContent = 'Reset'; }, 3000); return false;
}

export function updateDashboard(newCtx) { ctx = { ...ctx, ...newCtx }; if (!$('#view-dashboard').hidden) render(); }
export function showDashboard() { render(); }

function render() {
  miniMaps.forEach((m) => m.remove()); miniMaps = [];
  renderPages();
  // an ad slot after every 6 widgets for the free plan
  $('#dashGrid').innerHTML = layout.map((w, i) => widgetHTML(w) + ((i + 1) % 6 === 0 ? adSlot('inline') : '')).join('') + (layout.length % 6 ? adSlot('inline') : '');
  fillAds($('#dashGrid'));
  layout.forEach((w) => { if (w.type === 'minimap') mountMiniMap(w); });
  fillSiteSelects();
  $$('[data-hh]').forEach((el) => window.dispatchEvent(new CustomEvent('hail-history', { detail: el })));
  wireAlerts($('#dashGrid'));
}

function widgetHTML(w) {
  const def = WIDGETS[w.type]; if (!def) return '';
  const title = w.params?.title || def.title;
  const link = def.link || w.params?.link;
  return `<section class="widget w-${w.size}" data-id="${w.id}">
    <header class="w-head"><span class="w-grip" aria-hidden="true">⋮⋮</span><h3>${esc(title)}</h3>
      <div class="w-tools">${link ? `<a class="w-btn" href="${esc(link)}" target="_blank" rel="noopener" title="Open source">↗</a>` : ''}
      <button class="w-btn edit-only" data-act="size" title="Change size">${w.size.toUpperCase()}</button>
      <button class="w-btn edit-only" data-act="remove" title="Remove">✕</button></div></header>
    <div class="w-body">${bodyHTML(w, def)}</div></section>`;
}

function bodyHTML(w, def) {
  const { M, loc, models, afd } = ctx;
  if (def.kind === 'image' || w.type === 'custom_image') {
    const src = def.src || w.params?.src; const refresh = def.refresh || 10;
    return `<img class="w-img" loading="lazy" data-src="${esc(src)}" data-refresh="${refresh}" src="${esc(bust(src, refresh))}" alt="${esc(def.title || w.params?.title || '')}" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'empty',textContent:'Image unavailable right now'}))">${def.note ? `<div class="muted small">${esc(def.note)}</div>` : ''}`;
  }
  if (w.type === 'custom_link') return `<a class="big-link" href="${esc(w.params?.link)}" target="_blank" rel="noopener">${esc(w.params?.title || w.params?.link)} ↗</a>`;
  if (w.type === 'links') return linksHTML();
  if ((w.type === 'storms' || w.type === 'spaghetti') && !has('plus')) return `<div class="locked-card"><p>Live hurricane tracking, forecast cones and spaghetti model plots are part of Updraft Plus.</p><button class="btn" data-unlock="hurricanes">Unlock with Plus</button></div>`;
  if (w.type === 'storms') return stormsHTML(ctx.storms);
  if (w.type === 'spaghetti') return spaghettiHTML(ctx.storms);
  if (w.type === 'models_links') return modelLinksHTML();
  if (w.type === 'scales') return scalesHTML();
  if (w.type === 'marine_links') return marineHTML();
  if (w.type === 'site_loop') return has('pro') ? siteLoopHTML(w) : `<div class="locked-card"><p>Pick any of the 159 NEXRAD radars and watch its reflectivity or velocity loop. Part of Updraft Pro.</p><button class="btn" data-unlock="site">Unlock with Pro</button></div>`;
  if (w.type === 'hailhist') return '<div class="hail-hist" data-hh></div>';
  if (!M) return '<div class="empty">Loading…</div>';
  switch (w.type) {
    case 'now': return F.heroHTML(M, loc);
    case 'alerts': return `<div class="alert-list">${F.alertsHTML(M, true)}</div>`;
    case 'nowcast': return F.nowcastHTML(M);
    case 'hourly': return F.hourlyHTML(M, 48);
    case 'daily': return F.dailyHTML(M, 16);
    case 'details': return F.detailsHTML(M);
    case 'aqi': return F.aqHTML(M);
    case 'sun': return F.sunHTML(M);
    case 'nwstext': return `<div class="scroll-box">${F.nwsTextHTML(M)}</div>`;
    case 'models': return models ? F.modelsHTML(models) : '<div class="empty">Loading models…</div>';
    case 'afd': return afd === undefined ? '<div class="empty">Loading…</div>' : `<div class="scroll-box">${F.afdHTML(afd)}</div>`;
    case 'minimap': return '<div class="mini-map"></div>';
    case 'nwsloop': {
      const st = M.nws?.radar; if (!st) return '<div class="empty">Local NWS radar loops cover US locations only.</div>';
      return `<img class="w-img" data-src="https://radar.weather.gov/ridge/standard/${st}_loop.gif" data-refresh="5" src="${bust(`https://radar.weather.gov/ridge/standard/${st}_loop.gif`, 5)}" alt="${st} radar loop"><div class="muted small">Radar site ${esc(st)}</div>`;
    }
    default: return '';
  }
}
const bust = (src, min) => `${src}${src.includes('?') ? '&' : '?'}t=${Math.floor(Date.now() / (min * 60e3))}`;
function refreshImages() {
  $$('#dashGrid img.w-img').forEach((img) => { const n = bust(img.dataset.src, +img.dataset.refresh || 10); if (img.src !== n && !img.src.endsWith(n)) img.src = n; });
}

function linksHTML() {
  const office = ctx.M?.nws?.office;
  const links = [
    office && ['Your NWS Office', `https://www.weather.gov/${office.toLowerCase()}`],
    ['National Hurricane Center', 'https://www.nhc.noaa.gov/'],
    ['Storm Prediction Center', 'https://www.spc.noaa.gov/'],
    ['Weather Prediction Center', 'https://www.wpc.ncep.noaa.gov/'],
    ['Tropical Tidbits (models, spaghetti)', 'https://www.tropicaltidbits.com/'],
    ['Pivotal Weather (models)', 'https://www.pivotalweather.com/'],
    ['College of DuPage Models', 'https://weather.cod.edu/forecast/'],
    ['GOES Satellite Viewer', 'https://www.star.nesdis.noaa.gov/GOES/'],
    ['Mike\'s Weather Page', 'https://www.mikesweatherpage.com/'],
    ['Windy', 'https://www.windy.com/'],
  ].filter(Boolean);
  return `<div class="link-list">${links.map(([t, u]) => `<a href="${u}" target="_blank" rel="noopener">${esc(t)}<span>↗</span></a>`).join('')}</div>`;
}

// Spaghetti plots for every active storm (Tropical Tidbits), like spaghettimodels.com
const ttId = (s) => { const b = s.id?.slice(0, 2).toUpperCase(); return `${s.id?.slice(2, 4)}${{ AL: 'L', EP: 'E', CP: 'C' }[b] || 'L'}`; };
function spaghettiHTML(storms) {
  if (!storms) return '<div class="empty">Loading tropical data…</div>';
  if (!storms.length) return '<div class="empty ok">✓ No active storms, so no spaghetti plots right now.</div>' + modelLinksHTML();
  return `<div class="spag-grid">${storms.map((s) => { const id = ttId(s), src = `https://www.tropicaltidbits.com/storminfo/${id}_tracks_latest.png`, ens = `https://www.tropicaltidbits.com/storminfo/${id}_gefs_latest.png`;
    return `<div><h4>${esc(s.name)} <small class="muted">${id}</small></h4><img class="w-img" data-src="${src}" data-refresh="60" src="${bust(src, 60)}" alt="${esc(s.name)} model tracks"><img class="w-img" data-src="${ens}" data-refresh="60" src="${bust(ens, 60)}" alt="${esc(s.name)} GFS ensemble" onerror="this.remove()"></div>`; }).join('')}</div>`;
}
function modelLinksHTML() {
  const m = [['GFS', 'gfs'], ['Euro', 'ecmwf'], ['Canadian', 'cmc'], ['ICON', 'icon'], ['HRRR', 'hrrr'], ['NAM 3km', 'nam3km'], ['Euro AI', 'ecmwf-aifs'], ['GEFS', 'gfs-ens']];
  return `<div class="chips links">${m.map(([t, k]) => `<a href="https://www.tropicaltidbits.com/analysis/models/?model=${k}" target="_blank" rel="noopener">${t}</a>`).join('')}</div>
    <div class="link-list"><a href="https://www.tropicaltidbits.com/storminfo/" target="_blank" rel="noopener">Storm tracks & intensity<span>↗</span></a><a href="https://www.pivotalweather.com/model.php" target="_blank" rel="noopener">Pivotal Weather models<span>↗</span></a><a href="https://weather.cod.edu/forecast/" target="_blank" rel="noopener">College of DuPage models<span>↗</span></a><a href="https://www.nhc.noaa.gov/refresh/graphics_at1+shtml/" target="_blank" rel="noopener">NHC storm graphics<span>↗</span></a></div>`;
}
function scalesHTML() {
  const ss = [['TD', '< 39', '#5ebaff'], ['TS', '39-73', '#00faf4'], ['Cat 1', '74-95', '#ffffcc'], ['Cat 2', '96-110', '#ffe775'], ['Cat 3', '111-129', '#ffc140'], ['Cat 4', '130-156', '#ff8f20'], ['Cat 5', '157+', '#ff6060']];
  const ef = [['EF0', '65-85'], ['EF1', '86-110'], ['EF2', '111-135'], ['EF3', '136-165'], ['EF4', '166-200'], ['EF5', '200+']];
  const hail = [['0.75"', 'Penny'], ['1.00"', 'Quarter'], ['1.50"', 'Ping pong'], ['1.75"', 'Golf ball'], ['2.50"', 'Tennis ball'], ['2.75"', 'Baseball'], ['4.00"', 'Softball']];
  const t = (h, rows) => `<table class="scale"><tr>${h.map((x) => `<th>${x}</th>`).join('')}</tr>${rows}</table>`;
  return `<div class="scales"><div><h4>Saffir-Simpson (mph)</h4>${t(['Cat', 'Wind'], ss.map(([a, b, c]) => `<tr><td><i style="background:${c}"></i>${a}</td><td>${b}</td></tr>`).join(''))}</div>
    <div><h4>Enhanced Fujita (mph)</h4>${t(['Rating', 'Wind'], ef.map(([a, b]) => `<tr><td>${a}</td><td>${b}</td></tr>`).join(''))}</div>
    <div><h4>Hail size</h4>${t(['Size', 'Like a'], hail.map(([a, b]) => `<tr><td>${a}</td><td>${b}</td></tr>`).join(''))}</div></div>`;
}
function marineHTML() {
  const l = [['NDBC buoys', 'https://www.ndbc.noaa.gov/'], ['Tides & currents', 'https://tidesandcurrents.noaa.gov/'], ['Storm surge (NHC)', 'https://www.nhc.noaa.gov/surge/'], ['River forecasts', 'https://water.noaa.gov/'], ['Marine forecasts', 'https://www.weather.gov/marine/'], ['Rip current risk', 'https://www.weather.gov/safety/ripcurrent']];
  return `<div class="link-list">${l.map(([t, u]) => `<a href="${u}" target="_blank" rel="noopener">${t}<span>↗</span></a>`).join('')}</div>`;
}

// Any NEXRAD site, reflectivity or velocity loop (NWS RIDGE)
function siteLoopHTML(w) {
  const site = w.params?.site || ctx.M?.nws?.radar || 'KMLB', prod = w.params?.prod || 'ref';
  const src = `https://radar.weather.gov/ridge/standard/${prod === 'vel' ? 'base_velocity/' : ''}${site}_loop.gif`;
  return `<div class="site-ctl"><select data-site="${w.id}"><option value="${site}">${site}</option></select>
    <div class="seg small"><button data-sprod="ref" data-w="${w.id}" class="${prod === 'ref' ? 'on' : ''}">Reflectivity</button><button data-sprod="vel" data-w="${w.id}" class="${prod === 'vel' ? 'on' : ''}">Velocity</button></div></div>
    <img class="w-img" data-src="${src}" data-refresh="5" src="${bust(src, 5)}" alt="${site} radar loop">`;
}
async function fillSiteSelects() {
  const sels = $$('select[data-site]'); if (!sels.length) return;
  let list; try { list = await radarSites(); } catch { return; }
  const c = ctx.loc || { lat: 33.75, lon: -84.39 };
  const d = (x) => Math.round(Math.hypot(x.lat - c.lat, (x.lon - c.lon) * Math.cos(c.lat * Math.PI / 180)) * 69);
  const sorted = [...list].sort((a, b) => d(a) - d(b));
  sels.forEach((sel) => { const cur = sel.value; sel.innerHTML = sorted.map((x) => `<option value="${x.id}" ${x.id === cur ? 'selected' : ''}>${x.id} · ${esc(x.name)} (${d(x)} mi)</option>`).join(''); });
}

function stormsHTML(storms) {
  if (!storms) return '<div class="empty">Loading tropical data…</div>';
  if (!storms.length) return '<div class="empty ok">✓ No active tropical systems right now.</div><img class="w-img" data-src="https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png" data-refresh="30" src="' + bust('https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png', 30) + '" alt="NHC Atlantic outlook">';
  return storms.map((s) => {
    const n = s.id?.slice(2, 4), basin = s.id?.slice(0, 2).toUpperCase(), yr = s.id?.slice(4);
    const code = `${basin}${n}${yr}`;
    const cone = `https://www.nhc.noaa.gov/storm_graphics/${basin}${n}/${code}_5day_cone_with_line_and_wind.png`;
    const mph = Math.round((s.intensity || 0) * 1.15078);
    return `<div class="storm"><h4>${esc(s.classification === 'HU' ? 'Hurricane' : s.classification === 'TS' ? 'Tropical Storm' : 'Tropical System')} ${esc(s.name)}</h4>
      <div class="muted small">${mph} mph · ${esc(s.pressure)} mb · Updated ${esc(s.lastUpdate ? new Date(s.lastUpdate).toLocaleString() : '')}</div>
      <img class="w-img" data-src="${cone}" data-refresh="30" src="${bust(cone, 30)}" alt="${esc(s.name)} forecast cone">
      <div class="link-row"><a href="https://www.nhc.noaa.gov/" target="_blank" rel="noopener">NHC advisory ↗</a><a href="https://www.tropicaltidbits.com/storminfo/" target="_blank" rel="noopener">Spaghetti models ↗</a></div></div>`;
  }).join('');
}

function mountMiniMap(w) {
  const el = $(`.widget[data-id="${w.id}"] .mini-map`); if (!el || !ctx.loc) return;
  const m = L.map(el, { zoomControl: false, attributionControl: false, scrollWheelZoom: false }).setView([ctx.loc.lat, ctx.loc.lon], 7);
  const dark = document.documentElement.dataset.theme !== 'light';
  L.tileLayer(dark ? TILES.dark : TILES.light, { maxNativeZoom: 16 }).addTo(m);
  L.tileLayer(`https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/{z}/{x}/{y}.png?_=${Math.floor(Date.now() / 300e3)}`, { opacity: 0.8, maxNativeZoom: 12 }).addTo(m);
  L.tileLayer(dark ? TILES.darkLabels : TILES.lightLabels, { maxNativeZoom: 16 }).addTo(m);
  L.circleMarker([ctx.loc.lat, ctx.loc.lon], { radius: 6, color: '#fff', weight: 2, fillColor: '#38bdf8', fillOpacity: 1 }).addTo(m);
  el.addEventListener('dblclick', () => location.hash = '#radar');
  miniMaps.push(m);
}

function onGridChange(e) {
  const sel = e.target.closest('select[data-site]'); if (!sel) return;
  const w = layout.find((x) => x.id === sel.dataset.site); if (!w) return;
  w.params = { ...(w.params || {}), site: sel.value }; save(); render();
}
function onGridClick(e) {
  const sp = e.target.closest('[data-sprod]');
  if (sp) { const w = layout.find((x) => x.id === sp.dataset.w); if (w) { w.params = { ...(w.params || {}), prod: sp.dataset.sprod }; save(); render(); } return; }
  const un = e.target.closest('[data-unlock]'); if (un) { openPricing(un.dataset.unlock === 'site' ? 'Radar site loops are part of Updraft Pro.' : 'The hurricane tracker is part of Updraft Plus.'); return; }
  const b = e.target.closest('[data-act]'); const wEl = e.target.closest('.widget');
  if (b && wEl) {
    const w = layout.find((x) => x.id === wEl.dataset.id);
    if (b.dataset.act === 'remove') layout = layout.filter((x) => x !== w);
    if (b.dataset.act === 'size') w.size = SIZES[(SIZES.indexOf(w.size) + 1) % SIZES.length];
    save(); render(); return;
  }
  const img = e.target.closest('img.w-img');
  if (img && !editing) window.dispatchEvent(new CustomEvent('lightbox', { detail: { src: img.src, alt: img.alt } }));
}
function wireAlerts(root) {
  $$('[data-alert]', root).forEach((b) => b.onclick = () => window.dispatchEvent(new CustomEvent('show-alert', { detail: ctx.M.alerts[+b.dataset.alert] })));
}

// ---------- add-widget catalog ----------
function openCatalog() {
  const cats = {};
  for (const [id, d] of Object.entries(WIDGETS)) (cats[d.cat] ||= []).push([id, d]);
  const used = new Set(layout.map((w) => w.type));
  const html = `<div class="catalog">${Object.entries(cats).map(([c, list]) => `<h4>${esc(c)}</h4><div class="cat-grid">${list.map(([id, d]) => `
    <button class="cat-item${used.has(id) && d.kind !== 'custom' ? ' used' : ''}" data-add="${id}"><b>${esc(d.title)}</b><span>${used.has(id) && d.kind !== 'custom' ? 'On dashboard · add another' : 'Add'}</span></button>`).join('')}</div>`).join('')}
    <div id="customForm" hidden class="custom-form"><h4>Custom widget</h4>
      <label>Title<input id="cfTitle" placeholder="e.g. Euro ensemble"></label>
      <label id="cfSrcL">Image or GIF address<input id="cfSrc" placeholder="https://…/image.png"></label>
      <label>Click-through link (optional)<input id="cfLink" placeholder="https://…"></label>
      <button class="btn" id="cfSave">Add to dashboard</button></div></div>`;
  window.dispatchEvent(new CustomEvent('modal', { detail: { title: 'Add a widget', html } }));
  $$('[data-add]').forEach((b) => b.onclick = () => {
    const type = b.dataset.add, d = WIDGETS[type];
    if (d.kind === 'custom') {
      $('#customForm').hidden = false; $('#cfSrcL').hidden = type === 'custom_link'; $('#customForm').scrollIntoView({ behavior: 'smooth' });
      $('#cfSave').onclick = () => {
        const params = { title: $('#cfTitle').value.trim(), src: $('#cfSrc').value.trim(), link: $('#cfLink').value.trim() };
        if (type === 'custom_image' && !/^https:\/\//.test(params.src)) return toast('Enter an image address starting with https://');
        if (type === 'custom_link' && !/^https?:\/\//.test(params.link)) return toast('Enter a link starting with https://');
        add(type, params);
      };
      return;
    }
    add(type);
  });
}
function add(type, params) {
  layout.push({ id: uid(), type, size: WIDGETS[type].size || 'm', params });
  save(); render(); window.dispatchEvent(new CustomEvent('modal-close'));
  toast(`Added ${params?.title || WIDGETS[type].title}`);
  setTimeout(() => $('#dashGrid > .widget:last-child')?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 50);
}
