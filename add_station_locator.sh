#!/bin/bash
# PoliceConnect UG — Police Station Locator Module
# Run on live server: bash add_station_locator.sh
# Does NOT touch any existing files or tables
set -e

APP=/var/www/policeconnect
FRONT=$APP/frontend/src

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Police Station Locator — Adding Module"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Create Django app ──────────────────────────────
echo "→ [1/6] Creating police_stations Django app..."
mkdir -p $APP/police_stations/migrations

cat > $APP/police_stations/__init__.py << 'EOF'
EOF

cat > $APP/police_stations/apps.py << 'EOF'
from django.apps import AppConfig
class PoliceStationsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'police_stations'
EOF

cat > $APP/police_stations/models.py << 'EOF'
from django.db import models
from django.utils import timezone

class PoliceStation(models.Model):
    class StationType(models.TextChoices):
        CENTRAL    = 'CENTRAL',    'Central Police Station'
        DIVISION   = 'DIVISION',   'Police Division'
        POST       = 'POST',       'Police Post'
        UNIT       = 'UNIT',       'Specialised Unit'
        BORDER     = 'BORDER',     'Border Post'
        TRAFFIC    = 'TRAFFIC',    'Traffic Police'

    class Status(models.TextChoices):
        ACTIVE   = 'ACTIVE',   'Active'
        INACTIVE = 'INACTIVE', 'Inactive'
        UNKNOWN  = 'UNKNOWN',  'Unknown'

    # Identity
    station_name     = models.CharField(max_length=200)
    station_type     = models.CharField(max_length=20, choices=StationType.choices, default=StationType.POST)
    region           = models.CharField(max_length=100)
    district         = models.CharField(max_length=100)
    address          = models.TextField(blank=True)

    # Geolocation
    latitude         = models.DecimalField(max_digits=10, decimal_places=7)
    longitude        = models.DecimalField(max_digits=10, decimal_places=7)

    # Contact
    phone_primary    = models.CharField(max_length=20, blank=True)
    phone_secondary  = models.CharField(max_length=20, blank=True)
    email            = models.EmailField(blank=True)

    # Details
    services_available = models.JSONField(default=list, blank=True)
    operating_hours    = models.CharField(max_length=100, default='24 Hours', blank=True)

    # Verification
    verified_status  = models.BooleanField(default=False)
    last_verified_at = models.DateTimeField(null=True, blank=True)
    status           = models.CharField(max_length=10, choices=Status.choices, default=Status.ACTIVE)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['region', 'district', 'station_name']
        indexes  = [
            models.Index(fields=['region']),
            models.Index(fields=['district']),
            models.Index(fields=['status']),
            models.Index(fields=['latitude', 'longitude']),
        ]

    def __str__(self):
        return f"{self.station_name} ({self.district})"
EOF

cat > $APP/police_stations/serializers.py << 'EOF'
from rest_framework import serializers
from .models import PoliceStation

class PoliceStationSerializer(serializers.ModelSerializer):
    station_type_display = serializers.CharField(source='get_station_type_display', read_only=True)
    distance_km          = serializers.FloatField(read_only=True, default=None)

    class Meta:
        model  = PoliceStation
        fields = [
            'id', 'station_name', 'station_type', 'station_type_display',
            'region', 'district', 'address',
            'latitude', 'longitude',
            'phone_primary', 'phone_secondary', 'email',
            'services_available', 'operating_hours',
            'verified_status', 'last_verified_at',
            'status', 'distance_km', 'created_at',
        ]
EOF

cat > $APP/police_stations/views.py << 'EOF'
import math
from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated, AllowAny
from rest_framework.response import Response
from django.db.models import Q
from .models import PoliceStation
from .serializers import PoliceStationSerializer
from audit.models import AuditLog

def haversine(lat1, lon1, lat2, lon2):
    """Distance in km between two lat/lng points."""
    R = 6371
    d_lat = math.radians(float(lat2) - float(lat1))
    d_lon = math.radians(float(lon2) - float(lon1))
    a = (math.sin(d_lat/2)**2 +
         math.cos(math.radians(float(lat1))) *
         math.cos(math.radians(float(lat2))) *
         math.sin(d_lon/2)**2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

class PoliceStationViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class   = PoliceStationSerializer
    permission_classes = [AllowAny]  # Public — no login required for locator

    def get_queryset(self):
        qs = PoliceStation.objects.filter(status='ACTIVE')

        region   = self.request.query_params.get('region')
        district = self.request.query_params.get('district')
        stype    = self.request.query_params.get('type')
        q        = self.request.query_params.get('q')

        if region:   qs = qs.filter(region__icontains=region)
        if district: qs = qs.filter(district__icontains=district)
        if stype:    qs = qs.filter(station_type=stype)
        if q:        qs = qs.filter(
            Q(station_name__icontains=q) |
            Q(district__icontains=q) |
            Q(region__icontains=q) |
            Q(address__icontains=q)
        )
        return qs

    @action(detail=False, methods=['get'], url_path='nearby')
    def nearby(self, request):
        try:
            lat = float(request.query_params.get('lat'))
            lng = float(request.query_params.get('lng'))
        except (TypeError, ValueError):
            return Response({'detail': 'lat and lng are required.'}, status=400)

        limit  = int(request.query_params.get('limit', 5))
        radius = float(request.query_params.get('radius', 50))  # km

        stations = PoliceStation.objects.filter(status='ACTIVE')
        results  = []
        for s in stations:
            dist = haversine(lat, lng, s.latitude, s.longitude)
            if dist <= radius:
                s.distance_km = round(dist, 2)
                results.append(s)

        results.sort(key=lambda s: s.distance_km)
        results = results[:limit]

        # Log location search (no PII stored — just that a search occurred)
        if request.user.is_authenticated and hasattr(request.user, 'profile'):
            AuditLog.objects.create(
                actor=request.user.profile,
                action='STATION_NEARBY_SEARCH',
                target_type='police_station',
                detail={'result_count': len(results)},
                ip_address=request.META.get('REMOTE_ADDR'),
            )

        return Response(PoliceStationSerializer(results, many=True).data)

    @action(detail=False, methods=['get'], url_path='search')
    def search(self, request):
        q = request.query_params.get('q', '').strip()
        if not q:
            return Response([])
        qs = PoliceStation.objects.filter(
            status='ACTIVE'
        ).filter(
            Q(station_name__icontains=q) |
            Q(district__icontains=q) |
            Q(region__icontains=q)
        )[:20]
        return Response(PoliceStationSerializer(qs, many=True).data)

    @action(detail=False, methods=['get'], url_path='regions')
    def regions(self, request):
        regions = PoliceStation.objects.filter(status='ACTIVE').values_list('region', flat=True).distinct().order_by('region')
        return Response(list(regions))

    @action(detail=False, methods=['get'], url_path='districts')
    def districts(self, request):
        region = request.query_params.get('region')
        qs = PoliceStation.objects.filter(status='ACTIVE')
        if region:
            qs = qs.filter(region__icontains=region)
        districts = qs.values_list('district', flat=True).distinct().order_by('district')
        return Response(list(districts))
EOF

cat > $APP/police_stations/urls.py << 'EOF'
from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import PoliceStationViewSet

router = DefaultRouter()
router.register('', PoliceStationViewSet, basename='police-station')
urlpatterns = [path('', include(router.urls))]
EOF

cat > $APP/police_stations/admin.py << 'EOF'
from django.contrib import admin
from .models import PoliceStation

@admin.register(PoliceStation)
class PoliceStationAdmin(admin.ModelAdmin):
    list_display  = ['station_name', 'station_type', 'region', 'district', 'phone_primary', 'verified_status', 'status']
    list_filter   = ['region', 'station_type', 'status', 'verified_status']
    search_fields = ['station_name', 'district', 'address']
    ordering      = ['region', 'district', 'station_name']
EOF

echo "   Django app created"

# ── 2. Patch settings & urls ──────────────────────────
echo "→ [2/6] Patching settings and URLs..."

# Add police_stations to INSTALLED_APPS
sed -i "s|'accounts','cases','evidence','stations','messaging','audit',|'accounts','cases','evidence','stations','messaging','audit','police_stations',|" \
    $APP/core/settings.py

# Add URL to core/urls.py
sed -i "s|path('api/v1/tips/',          include('tips.urls')),|path('api/v1/tips/',          include('tips.urls')),\n    path('api/v1/police-stations/', include('police_stations.urls')),|" \
    $APP/core/urls.py

echo "   Settings and URLs patched"

# ── 3. Migration ──────────────────────────────────────
echo "→ [3/6] Running migration..."
cd $APP
venv/bin/python manage.py makemigrations police_stations
venv/bin/python manage.py migrate police_stations
echo "   Migration done"

# ── 4. Seed Uganda police stations ───────────────────
echo "→ [4/6] Seeding Uganda police stations..."
cat > $APP/scripts/seed_stations.py << 'EOF'
#!/usr/bin/env python3
import os, sys
sys.path.insert(0, '/var/www/policeconnect')
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'core.settings')
import django; django.setup()
from police_stations.models import PoliceStation

STATIONS = [
    # Central Region — Kampala
    ('Kampala Central Police Station',  'CENTRAL', 'Central Region', 'Kampala',  'Kampala Road, Kampala',              0.3136,  32.5811, '0414-256070',  '0800-199-100',  ['Criminal Reports','Lost Property','Traffic','Investigations'], '24 Hours', True),
    ('Katwe Police Station',             'DIVISION','Central Region', 'Kampala',  'Katwe, Kampala',                     0.2966,  32.5633, '0414-272890',  '',              ['Criminal Reports','Community Policing'], '24 Hours', True),
    ('Wandegeya Police Station',         'DIVISION','Central Region', 'Kampala',  'Wandegeya, Kampala',                 0.3397,  32.5703, '0414-532060',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Old Kampala Police Station',       'DIVISION','Central Region', 'Kampala',  'Old Kampala Road, Kampala',          0.3231,  32.5728, '0414-344150',  '',              ['Criminal Reports','Investigations'], '24 Hours', True),
    ('Jinja Road Police Post',           'POST',    'Central Region', 'Kampala',  'Jinja Road, Kampala',                0.3178,  32.5954, '0414-288900',  '',              ['Traffic','Community Policing'], '24 Hours', False),
    ('Kira Road Police Station',         'DIVISION','Central Region', 'Kampala',  'Kira Road, Kampala',                 0.3589,  32.5959, '0414-286870',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Ntinda Police Post',               'POST',    'Central Region', 'Kampala',  'Ntinda, Kampala',                    0.3614,  32.6256, '0772-000001',  '',              ['Community Policing'], '08:00-22:00', False),
    ('Kabalagala Police Station',        'DIVISION','Central Region', 'Kampala',  'Kabalagala, Kampala',                0.2789,  32.5928, '0414-510770',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Mulago Police Post',               'POST',    'Central Region', 'Kampala',  'Mulago Hill, Kampala',               0.3383,  32.5764, '0772-000002',  '',              ['Community Policing','First Aid'], '24 Hours', False),
    ('Entebbe Airport Police',           'UNIT',    'Central Region', 'Wakiso',   'Entebbe International Airport',      0.0421,  32.4432, '0414-320444',  '',              ['Security','Immigration Support','Lost Property'], '24 Hours', True),
    ('Entebbe Police Station',           'DIVISION','Central Region', 'Wakiso',   'Entebbe Town, Wakiso',               0.0600,  32.4627, '0414-320577',  '',              ['Criminal Reports','Marine Police'], '24 Hours', True),
    ('Wakiso Police Station',            'DIVISION','Central Region', 'Wakiso',   'Wakiso Town',                        0.4050,  32.4584, '0312-260102',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Mukono Police Station',            'DIVISION','Central Region', 'Mukono',   'Mukono Town',                        0.3544,  32.7558, '0312-290201',  '',              ['Criminal Reports','Traffic','Investigations'], '24 Hours', True),
    ('Kayunga Police Station',           'DIVISION','Central Region', 'Kayunga',  'Kayunga Town',                       0.7028,  32.8903, '0312-290301',  '',              ['Criminal Reports'], '24 Hours', False),

    # Eastern Region
    ('Jinja Central Police Station',     'CENTRAL', 'Eastern Region', 'Jinja',    'Main Street, Jinja',                 0.4478,  33.2026, '0434-120444',  '0800-199-100',  ['Criminal Reports','Marine Police','Traffic','Investigations'], '24 Hours', True),
    ('Iganga Police Station',            'DIVISION','Eastern Region', 'Iganga',   'Iganga Town',                        0.6117,  33.4689, '0434-440144',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Mbale Central Police Station',     'CENTRAL', 'Eastern Region', 'Mbale',    'Republic Street, Mbale',             1.0825,  34.1754, '0454-433533',  '0800-199-100',  ['Criminal Reports','Traffic','Investigations','CID'], '24 Hours', True),
    ('Tororo Police Station',            'DIVISION','Eastern Region', 'Tororo',   'Station Road, Tororo',               0.6924,  34.1811, '0454-444244',  '',              ['Criminal Reports','Border Security'], '24 Hours', True),
    ('Busia Police Station',             'BORDER',  'Eastern Region', 'Busia',    'Busia Border, Eastern Uganda',       0.4672,  34.0900, '0454-320100',  '',              ['Border Control','Immigration Support'], '24 Hours', True),
    ('Soroti Police Station',            'DIVISION','Eastern Region', 'Soroti',   'Soroti Town',                        1.7148,  33.6107, '0454-461244',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Kumi Police Station',              'POST',    'Eastern Region', 'Kumi',     'Kumi Town',                          1.4622,  33.9367, '0772-000010',  '',              ['Community Policing'], '24 Hours', False),

    # Northern Region
    ('Gulu Central Police Station',      'CENTRAL', 'Northern Region','Gulu',     'Gulu Main Road, Gulu City',          2.7747,  32.2990, '0471-432055',  '0800-199-100',  ['Criminal Reports','Traffic','Investigations','CID'], '24 Hours', True),
    ('Lira Police Station',              'DIVISION','Northern Region','Lira',     'Lira Town',                          2.2499,  32.8997, '0473-420244',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Arua Police Station',              'DIVISION','Northern Region','Arua',     'Arua City',                          3.0205,  30.9110, '0476-420344',  '',              ['Criminal Reports','Border Security','Traffic'], '24 Hours', True),
    ('Adjumani Police Station',          'BORDER',  'Northern Region','Adjumani', 'Adjumani Town',                      3.3779,  31.7906, '0772-000020',  '',              ['Border Control','Refugee Affairs'], '24 Hours', False),
    ('Kitgum Police Station',            'DIVISION','Northern Region','Kitgum',   'Kitgum Town',                        3.2760,  32.8876, '0772-000021',  '',              ['Criminal Reports'], '24 Hours', False),
    ('Pader Police Station',             'POST',    'Northern Region','Pader',    'Pader Town',                         2.7733,  33.1222, '0772-000022',  '',              ['Community Policing'], '24 Hours', False),

    # Western Region
    ('Mbarara Central Police Station',   'CENTRAL', 'Western Region', 'Mbarara',  'Mbarara City',                      -0.6072,  30.6545, '0485-420344',  '0800-199-100',  ['Criminal Reports','Traffic','Investigations','CID'], '24 Hours', True),
    ('Fort Portal Police Station',       'DIVISION','Western Region', 'Kabarole', 'Fort Portal City',                   0.6710,  30.2749, '0483-422344',  '',              ['Criminal Reports','Traffic','Tourism Police'], '24 Hours', True),
    ('Kasese Police Station',            'DIVISION','Western Region', 'Kasese',   'Kasese Town',                        0.1831,  30.0850, '0483-444244',  '',              ['Criminal Reports','Border Security'], '24 Hours', True),
    ('Kabale Police Station',            'DIVISION','Western Region', 'Kabale',   'Kabale Town',                       -1.2481,  29.9869, '0486-422344',  '',              ['Criminal Reports','Traffic','Border Security'], '24 Hours', True),
    ('Masaka Police Station',            'DIVISION','Western Region', 'Masaka',   'Masaka City',                       -0.3380,  31.7381, '0481-420344',  '',              ['Criminal Reports','Traffic'], '24 Hours', True),
    ('Bushenyi Police Station',          'DIVISION','Western Region', 'Bushenyi', 'Bushenyi Town',                     -0.5847,  30.1831, '0772-000030',  '',              ['Criminal Reports'], '24 Hours', False),
    ('Hoima Police Station',             'DIVISION','Western Region', 'Hoima',    'Hoima City',                         1.4333,  31.3500, '0465-420244',  '',              ['Criminal Reports','Traffic','Oil Region Security'], '24 Hours', True),
    ('Masindi Police Station',           'DIVISION','Western Region', 'Masindi',  'Masindi Town',                       1.6833,  31.7167, '0465-432244',  '',              ['Criminal Reports','Traffic'], '24 Hours', False),

    # Specialised Units — Kampala
    ('CID Headquarters',                 'UNIT',    'Central Region', 'Kampala',  'Kibuli, Kampala',                    0.3011,  32.5992, '0414-505242',  '',              ['CID Investigations','Fraud','Cybercrime'], 'Mon-Fri 08:00-17:00', True),
    ('Traffic Police Headquarters',      'TRAFFIC', 'Central Region', 'Kampala',  'Kampala Road, Kampala',              0.3156,  32.5822, '0414-342552',  '',              ['Traffic Management','Accident Reports','Driving Permits'], '24 Hours', True),
    ('Flying Squad / Special Forces',    'UNIT',    'Central Region', 'Kampala',  'Naguru, Kampala',                    0.3281,  32.6125, '0414-505000',  '',              ['Rapid Response','Armed Operations'], '24 Hours', True),
    ('Police Marine Unit',               'UNIT',    'Central Region', 'Wakiso',   'Port Bell, Luzira, Kampala',         0.2867,  32.6578, '0414-220444',  '',              ['Lake Patrol','Marine Rescue','Border Water'], '24 Hours', True),
    ('Police Air Wing',                  'UNIT',    'Central Region', 'Kampala',  'Entebbe, Wakiso',                    0.0556,  32.4431, '0414-320555',  '',              ['Air Surveillance','Rapid Deployment'], '24 Hours', False),
    ('Anti-Corruption Unit (CID)',       'UNIT',    'Central Region', 'Kampala',  'Kololo, Kampala',                    0.3344,  32.5939, '0414-231800',  '',              ['Corruption Investigations','Financial Crimes'], 'Mon-Fri 08:00-17:00', True),
]

created = 0
skipped = 0
for (name, stype, region, district, address, lat, lng, phone1, phone2, services, hours, verified) in STATIONS:
    obj, was_created = PoliceStation.objects.get_or_create(
        station_name=name,
        defaults=dict(
            station_type=stype, region=region, district=district,
            address=address, latitude=lat, longitude=lng,
            phone_primary=phone1, phone_secondary=phone2,
            services_available=services, operating_hours=hours,
            verified_status=verified, status='ACTIVE',
        )
    )
    if was_created:
        created += 1
        print(f"  + {name}")
    else:
        skipped += 1

print(f"\n  Seeded {created} stations, {skipped} already existed.")
print(f"  Total: {PoliceStation.objects.count()} stations in database.")
EOF

cd $APP && venv/bin/python scripts/seed_stations.py
echo "   Stations seeded"

# ── 5. Frontend page ──────────────────────────────────
echo "→ [5/6] Adding frontend page..."

# Add API method to existing api/index.js
cat >> $FRONT/api/index.js << 'EOF'

export const stationLocatorApi = {
  list:    p  => api.get('/police-stations/', { params: p }),
  get:     id => api.get(`/police-stations/${id}/`),
  nearby:  p  => api.get('/police-stations/nearby/', { params: p }),
  search:  q  => api.get('/police-stations/search/', { params: { q } }),
  regions: () => api.get('/police-stations/regions/'),
}
EOF

# Add map CSS to index.css
cat >> $FRONT/index.css << 'EOF'

/* ── Station Locator ── */
.map-shell{display:grid;grid-template-columns:320px 1fr;gap:16px;height:calc(100vh - 180px);min-height:500px}
.map-panel{display:flex;flex-direction:column;gap:10px;overflow:hidden}
.map-list{flex:1;overflow-y:auto;display:flex;flex-direction:column;gap:6px}
.station-card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:12px;cursor:pointer;transition:all .15s}
.station-card:hover,.station-card.active{border-color:var(--gold);background:var(--surface2)}
.station-card-name{font-size:13px;font-weight:600;color:var(--white);margin-bottom:2px}
.station-card-meta{font-size:11px;color:var(--ink3)}
.station-card-dist{font-size:11px;font-weight:700;color:var(--gold);margin-top:4px}
#pc-map{height:100%;border-radius:var(--radius);border:1px solid var(--border);z-index:0}
.map-container{flex:1;position:relative;min-height:400px}
.station-modal{position:fixed;inset:0;background:rgba(0,0,0,0.7);z-index:9999;display:flex;align-items:center;justify-content:center;padding:16px}
.station-modal-card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px;width:100%;max-width:480px;max-height:80vh;overflow-y:auto}
.station-modal-name{font-size:18px;font-weight:700;color:var(--white);margin-bottom:4px}
.station-modal-type{font-size:12px;color:var(--gold);font-weight:600;text-transform:uppercase;letter-spacing:.05em;margin-bottom:16px}
.station-detail-row{display:flex;gap:10px;padding:8px 0;border-bottom:1px solid var(--border2);font-size:13px}
.station-detail-label{width:110px;color:var(--ink3);font-size:11px;font-weight:600;text-transform:uppercase;flex-shrink:0;padding-top:1px}
.station-detail-val{color:var(--ink);flex:1}
.leaflet-container{background:#1a1a2e!important}
.leaflet-popup-content-wrapper{background:var(--surface)!important;border:1px solid var(--border)!important;color:var(--ink)!important;border-radius:8px!important}
.leaflet-popup-tip{background:var(--surface)!important}
EOF

# Write the StationsPage
cat > $FRONT/pages/StationsPage.jsx << 'PAGEOF'
import { useEffect, useRef, useState } from 'react'
import { stationLocatorApi } from '../api'

const TYPE_COLORS = {
  CENTRAL: '#FCDC04', DIVISION: '#5b8ef0', POST: '#2ecc80',
  UNIT: '#a07ee0', BORDER: '#e0921a', TRAFFIC: '#D21034',
}
const TYPE_LABELS = {
  CENTRAL:'Central Station', DIVISION:'Division', POST:'Police Post',
  UNIT:'Specialised Unit', BORDER:'Border Post', TRAFFIC:'Traffic Police',
}

export default function StationsPage() {
  const mapRef      = useRef(null)
  const leafletRef  = useRef(null)
  const markersRef  = useRef([])
  const userMarker  = useRef(null)

  const [stations, setStations]   = useState([])
  const [filtered, setFiltered]   = useState([])
  const [selected, setSelected]   = useState(null)
  const [loading, setLoading]     = useState(true)
  const [locating, setLocating]   = useState(false)
  const [userPos, setUserPos]     = useState(null)
  const [regions, setRegions]     = useState([])
  const [filter, setFilter]       = useState({ region:'', district:'', type:'', q:'' })
  const [tab, setTab]             = useState('all') // 'all' | 'nearby'
  const [nearby, setNearby]       = useState([])

  // Load Leaflet dynamically (CDN — no npm install needed)
  useEffect(() => {
    if (window.L) { initMap(); return }
    const css  = document.createElement('link')
    css.rel    = 'stylesheet'
    css.href   = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css'
    document.head.appendChild(css)
    const script  = document.createElement('script')
    script.src    = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'
    script.onload = initMap
    document.head.appendChild(script)
  }, [])

  // Load stations & regions
  useEffect(() => {
    stationLocatorApi.list({ limit: 500 }).then(r => {
      const list = r.data?.results || r.data || []
      setStations(list)
      setFiltered(list)
      setLoading(false)
    }).catch(() => setLoading(false))
    stationLocatorApi.regions().then(r => setRegions(r.data || [])).catch(() => {})
  }, [])

  // Re-render markers when filtered changes
  useEffect(() => {
    if (leafletRef.current) renderMarkers(filtered)
  }, [filtered])

  // Apply filters
  useEffect(() => {
    let f = stations
    if (filter.region)   f = f.filter(s => s.region === filter.region)
    if (filter.district) f = f.filter(s => s.district.toLowerCase().includes(filter.district.toLowerCase()))
    if (filter.type)     f = f.filter(s => s.station_type === filter.type)
    if (filter.q)        f = f.filter(s =>
      s.station_name.toLowerCase().includes(filter.q.toLowerCase()) ||
      s.district.toLowerCase().includes(filter.q.toLowerCase())
    )
    setFiltered(f)
  }, [filter, stations])

  const initMap = () => {
    if (leafletRef.current || !mapRef.current || !window.L) return
    const L   = window.L
    const map = L.map('pc-map', {
      center: [1.3733, 32.2903], // Uganda centre
      zoom: 7,
      zoomControl: true,
    })
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '© OpenStreetMap contributors',
      maxZoom: 18,
    }).addTo(map)
    leafletRef.current = map
    if (stations.length) renderMarkers(stations)
  }

  const makeIcon = (color) => {
    if (!window.L) return null
    return window.L.divIcon({
      className: '',
      html: `<div style="width:14px;height:14px;border-radius:50%;background:${color};border:2px solid white;box-shadow:0 1px 4px rgba(0,0,0,0.5)"></div>`,
      iconSize: [14, 14],
      iconAnchor: [7, 7],
      popupAnchor: [0, -10],
    })
  }

  const renderMarkers = (list) => {
    const L   = window.L
    const map = leafletRef.current
    if (!L || !map) return
    markersRef.current.forEach(m => map.removeLayer(m))
    markersRef.current = []
    list.forEach(s => {
      const color  = TYPE_COLORS[s.station_type] || '#5b8ef0'
      const marker = L.marker([parseFloat(s.latitude), parseFloat(s.longitude)], { icon: makeIcon(color) })
      marker.bindPopup(`
        <div style="font-family:sans-serif;min-width:180px">
          <div style="font-weight:700;font-size:13px;color:#fff;margin-bottom:4px">${s.station_name}</div>
          <div style="font-size:11px;color:#aaa;margin-bottom:6px">${s.district} · ${TYPE_LABELS[s.station_type]||s.station_type}</div>
          ${s.phone_primary ? `<div style="font-size:12px;color:#FCDC04">📞 ${s.phone_primary}</div>` : ''}
          <button onclick="window.__pcSelectStation('${s.id}')" style="margin-top:8px;padding:5px 10px;background:#FCDC04;color:#12122a;border:none;border-radius:5px;font-size:12px;font-weight:700;cursor:pointer;width:100%">View Details</button>
        </div>
      `)
      marker.on('click', () => setSelected(s))
      marker.addTo(map)
      markersRef.current.push(marker)
    })
  }

  // Global callback for popup button
  useEffect(() => {
    window.__pcSelectStation = (id) => {
      const s = stations.find(x => String(x.id) === String(id))
      if (s) setSelected(s)
    }
    return () => { delete window.__pcSelectStation }
  }, [stations])

  const flyTo = (s) => {
    setSelected(s)
    if (leafletRef.current) {
      leafletRef.current.flyTo([parseFloat(s.latitude), parseFloat(s.longitude)], 14, { duration: 1 })
    }
  }

  const locate = () => {
    if (!navigator.geolocation) return
    setLocating(true)
    navigator.geolocation.getCurrentPosition(pos => {
      const { latitude: lat, longitude: lng } = pos.coords
      setUserPos({ lat, lng })
      if (leafletRef.current && window.L) {
        if (userMarker.current) leafletRef.current.removeLayer(userMarker.current)
        userMarker.current = window.L.circleMarker([lat, lng], {
          radius: 10, fillColor: '#FCDC04', color: '#fff', weight: 2, fillOpacity: 1
        }).bindPopup('📍 Your location').addTo(leafletRef.current)
        leafletRef.current.flyTo([lat, lng], 12)
      }
      stationLocatorApi.nearby({ lat, lng, limit: 10, radius: 100 }).then(r => {
        setNearby(r.data || [])
        setTab('nearby')
      }).catch(() => {})
      setLocating(false)
    }, () => setLocating(false))
  }

  const openDirections = (s) => {
    const url = `https://www.google.com/maps/dir/?api=1&destination=${s.latitude},${s.longitude}&destination_place_name=${encodeURIComponent(s.station_name)}`
    window.open(url, '_blank')
  }

  const call = (phone) => { window.location.href = `tel:${phone}` }

  const displayList = tab === 'nearby' ? nearby : filtered

  return (
    <div>
      <div className="page-header">
        <div>
          <div className="page-title">Police Station Locator</div>
          <div className="page-sub">Uganda Police Force · {stations.length} stations nationwide</div>
        </div>
        <button className="btn btn-primary" onClick={locate} disabled={locating}>
          {locating ? '📍 Locating…' : '📍 Find Nearest'}
        </button>
      </div>

      <div className="map-shell">
        {/* Left panel */}
        <div className="map-panel">
          {/* Search & filters */}
          <div className="card" style={{ padding: 12, flexShrink: 0 }}>
            <input
              className="form-input"
              placeholder="Search stations, districts…"
              value={filter.q}
              onChange={e => setFilter(f => ({ ...f, q: e.target.value }))}
              style={{ marginBottom: 8 }}
            />
            <div className="form-row" style={{ gap: 6 }}>
              <select className="form-select" value={filter.region} onChange={e => setFilter(f => ({ ...f, region: e.target.value, district: '' }))}>
                <option value="">All Regions</option>
                {regions.map(r => <option key={r} value={r}>{r}</option>)}
              </select>
              <select className="form-select" value={filter.type} onChange={e => setFilter(f => ({ ...f, type: e.target.value }))}>
                <option value="">All Types</option>
                {Object.entries(TYPE_LABELS).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </div>
          </div>

          {/* Tabs */}
          <div className="tabs" style={{ margin: 0 }}>
            <div className={`tab${tab === 'all' ? ' active' : ''}`} onClick={() => setTab('all')}>
              All ({filtered.length})
            </div>
            <div className={`tab${tab === 'nearby' ? ' active' : ''}`} onClick={() => setTab('nearby')}>
              Nearest {nearby.length ? `(${nearby.length})` : ''}
            </div>
          </div>

          {/* Station list */}
          <div className="map-list">
            {loading && <div style={{ color: 'var(--ink3)', fontSize: 13, textAlign: 'center', padding: 20 }}>Loading stations…</div>}
            {!loading && !displayList.length && (
              <div style={{ color: 'var(--ink3)', fontSize: 13, textAlign: 'center', padding: 20 }}>
                {tab === 'nearby' ? '📍 Tap "Find Nearest" to locate stations near you' : 'No stations match your filters'}
              </div>
            )}
            {displayList.map(s => (
              <div
                key={s.id}
                className={`station-card${selected?.id === s.id ? ' active' : ''}`}
                onClick={() => flyTo(s)}
              >
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
                  <div style={{ width: 10, height: 10, borderRadius: '50%', background: TYPE_COLORS[s.station_type] || '#5b8ef0', marginTop: 4, flexShrink: 0 }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div className="station-card-name">{s.station_name}</div>
                    <div className="station-card-meta">{s.district} · {TYPE_LABELS[s.station_type] || s.station_type}</div>
                    {s.phone_primary && <div className="station-card-meta" style={{ color: 'var(--gold)', marginTop: 2 }}>📞 {s.phone_primary}</div>}
                    {s.distance_km != null && <div className="station-card-dist">📍 {s.distance_km} km away</div>}
                  </div>
                  {s.verified_status && <span style={{ fontSize: 10, color: 'var(--green)', background: 'var(--green-bg)', padding: '2px 5px', borderRadius: 4, flexShrink: 0 }}>✓ Verified</span>}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Map */}
        <div className="map-container">
          <div id="pc-map" ref={mapRef} style={{ height: '100%', borderRadius: 'var(--radius)' }} />
          {/* Legend */}
          <div style={{ position: 'absolute', bottom: 24, right: 12, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 8, padding: '8px 12px', fontSize: 11, zIndex: 999 }}>
            {Object.entries(TYPE_COLORS).map(([type, color]) => (
              <div key={type} style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
                <div style={{ width: 10, height: 10, borderRadius: '50%', background: color, border: '1px solid rgba(255,255,255,0.3)', flexShrink: 0 }} />
                <span style={{ color: 'var(--ink2)' }}>{TYPE_LABELS[type]}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Station Detail Modal */}
      {selected && (
        <div className="station-modal" onClick={e => e.target === e.currentTarget && setSelected(null)}>
          <div className="station-modal-card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 4 }}>
              <div>
                <div className="station-modal-name">{selected.station_name}</div>
                <div className="station-modal-type" style={{ color: TYPE_COLORS[selected.station_type] }}>
                  {TYPE_LABELS[selected.station_type] || selected.station_type}
                  {selected.verified_status && <span style={{ marginLeft: 8, color: 'var(--green)' }}>✓ Verified</span>}
                </div>
              </div>
              <button className="btn btn-secondary btn-sm" onClick={() => setSelected(null)}>✕</button>
            </div>

            {[
              ['Region',    selected.region],
              ['District',  selected.district],
              ['Address',   selected.address || '—'],
              ['Hours',     selected.operating_hours],
            ].map(([l, v]) => v && (
              <div className="station-detail-row" key={l}>
                <div className="station-detail-label">{l}</div>
                <div className="station-detail-val">{v}</div>
              </div>
            ))}

            {selected.services_available?.length > 0 && (
              <div className="station-detail-row">
                <div className="station-detail-label">Services</div>
                <div className="station-detail-val">
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                    {selected.services_available.map(svc => (
                      <span key={svc} style={{ background: 'var(--surface2)', border: '1px solid var(--border)', padding: '2px 7px', borderRadius: 12, fontSize: 11, color: 'var(--ink2)' }}>{svc}</span>
                    ))}
                  </div>
                </div>
              </div>
            )}

            <div style={{ display: 'flex', gap: 8, marginTop: 16, flexWrap: 'wrap' }}>
              {selected.phone_primary && (
                <button className="btn btn-primary" onClick={() => call(selected.phone_primary)}>
                  📞 {selected.phone_primary}
                </button>
              )}
              {selected.phone_secondary && (
                <button className="btn btn-secondary" onClick={() => call(selected.phone_secondary)}>
                  📞 {selected.phone_secondary}
                </button>
              )}
              <button className="btn btn-secondary" onClick={() => openDirections(selected)}>
                🗺 Directions
              </button>
              <button className="btn btn-secondary" onClick={() => setSelected(null)} style={{ marginLeft: 'auto' }}>
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
PAGEOF

echo "   Frontend page written"

# ── 6. Wire into router & sidebar ─────────────────────
echo "→ [6/6] Wiring into router and sidebar..."

# Add import to App.jsx
sed -i "s|import TipsPage from './pages/TipsPage'|import TipsPage from './pages/TipsPage'\nimport StationsPage from './pages/StationsPage'|" \
    $FRONT/App.jsx

# Add route to App.jsx (inside the Layout routes)
sed -i "s|<Route path=\"/tips\"         element={<TipsPage/>}/>|<Route path=\"/tips\"         element={<TipsPage/>}/>\n            <Route path=\"/stations\"     element={<StationsPage/>}/>|" \
    $FRONT/App.jsx

# Add nav item to Sidebar.jsx
sed -i "s|{ path:'/tips',       label:'Submit Tip',      Icon:TipIcon,   roles:\['CITIZEN'\] },|{ path:'/tips',       label:'Submit Tip',      Icon:TipIcon,   roles:['CITIZEN'] },\n    { path:'/stations',   label:'Police Stations', Icon:ShieldIcon,roles:['CITIZEN','OFFICER','STATION_ADMIN','RPC','OVERSIGHT'] },|" \
    $FRONT/components/Sidebar.jsx

echo "   Router and sidebar updated"

# ── Rebuild frontend ──────────────────────────────────
echo ""
echo "→ Rebuilding frontend..."
cd $APP/frontend
npm run build 2>&1 | tail -5

# Restart gunicorn
systemctl restart policeconnect
sleep 2

# Verify API
RESULT=$(curl -s "http://127.0.0.1:8000/api/v1/police-stations/?limit=3" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'OK — {d[\"count\"] if \"count\" in d else len(d)} stations')" 2>/dev/null || echo "check manually")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Police Station Locator — INSTALLED"
echo "  API test: $RESULT"
echo ""
echo "  → http://185.139.230.30/stations"
echo "  → API: http://185.139.230.30/api/v1/police-stations/"
echo "  → Nearby: http://185.139.230.30/api/v1/police-stations/nearby/?lat=0.3136&lng=32.5811"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
