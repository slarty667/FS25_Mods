# WayPointGPS — Pfadfindung sauber reverse-engineered (2026-06-17)

Quelle: `tmp/wpgps/scripts/WayPointGPS.lua` (7027 Z.). Alle Zeilennummern darauf bezogen.
Erstellt im Mr.-Winston-Wolf-Pass. **Wichtigster Befund zuerst, dann die Mechanik.**

## 0. Der entscheidende Befund (warum WPGPS auf Helden "funktioniert")

WPGPS hat **zwei Graph-Welten**, die sich nur den A* teilen:

1. **Route-Graph** (`graph.isRouteGraph = true`): geladen aus **gebündelter XML**
   (`buildWaypointRouteGraph`, Z.2639 / `tryLoadWaypointRouteGraph`, Z.2745). Knoten + Kanten
   kommen **aus der Datei**, nicht aus der Szene. → `tmp/wpgps/routes/<Map>.wpg.xml`.
   **Helden.wpg.xml = 10.911 Wegpunkte, 73 fieldBranchSeeds, ganze Karte.** 50 Karten haben so eine Datei.
2. **AI-Spline-Graph** (Fallback): zur Laufzeit aus der Szene gescannt (`ensureAIRoadGraph`, Z.2806).

**Auf einer Karte mit gebündelter XML nutzt WPGPS Welt 1 — nicht Live-Berechnung.** Terrain-Farbe
+ Spline-Scan sind nur für Karten *ohne* gebündelten Graph. Genau die scheitern auf Helden.

## 1. Engine-APIs zur Spline-Erkennung (Welt 2, Fallback)

- `getSplineLength(node)` (Z.1555), nur `20 < len < 100000` akzeptiert (Z.1556).
- `getSplinePosition(node, t∈[0,1])` (Z.1564) → x,z.
- Szenen-Walk rekursiv via `getNumOfChildren`/`getChildAt` (Z.1795–1804). **Keine** `roadSplines`-API.
- Knoten-Gate `aiRoadNodeIsSafeSplineCandidate` (Z.1504): `entityExists` + `getHasClassId(node, ClassIds.SHAPE)`
  (sonst loggt `getSplineLength` selbst in pcall einen GIANTS-Fehler) + Namensheuristik.
- **Gescannte Wurzeln** (Z.2837–2841): `terrainRootNode`, `rootNode`, `mapRootNode`.
- **Tabellen-Scan** (Z.2829–2835): blinder rekursiver Walk über `trafficSystem` + `aiSystem`
  (jeder `number`-Wert = potenzielle Node-ID), Pfad-Filter `aiRoadPathLooksUseful` (Z.1485):
  muss `traffic|road|street|drive|vehicle|ai|car` enthalten, NICHT `water|river|rail|pedestrian|field`.

## 2. Spline → Knoten/Kanten + Bucketing

- Sampling `aiRoadGraphAddSpline` (Z.1703): `count = max(2, ceil(len/18))`, **Spacing ≈ 18 m**
  (`AI_ROAD_SAMPLE_DISTANCE=18`, Z.150). Aufeinanderfolgende Samples → Kette via `aiRoadGraphAddEdge`.
- Knoten `aiRoadGraphAddNode` (Z.1571): `{x,z}`, Bucket-Key `floor(x/24):floor(z/24)`
  (`AI_ROAD_BUCKET_SIZE=24`). **Kein Merge beim Einfügen** — Buckets nur als Spatial-Index.
- Kanten `aiRoadGraphAddEdge` (Z.1592): Kosten = 2D-Distanz, verworfen `<0.1` oder `>80`, ungerichtet.
- Kreuzungs-Verschmelzung `aiRoadConnectIntersections` (Z.1808): jeder Knoten ↔ andere Knoten
  in `AI_ROAD_INTERSECTION_RADIUS=24` bekommen Kante. **Das ist der Merge-Ersatz.**

## 3. Komponenten-Stitching (Brücken/Lücken) — `finalizeAIRoadGraph` (Z.2791)

- Komponenten via BFS `aiRoadBuildComponents` (Z.1841).
- `aiRoadStitchNearbyComponents` (Z.1920): Radius 58, Cost-Cap 72 — kurze Lücken/Kreuzungen.
- `aiRoadStitchBridgeComponents` (Z.1976) + `aiRoadStitchBridgeHubs` (Z.2033): nur bei
  Brücken-Objekten (`bridge|causeway|ford|ferry|crossing|overpass`), Radius 285–340.

## 4. A* — `buildAIRoadGraphRoute` (Z.3187)

Binärheap, gemeinsam für beide Welten. Multi-Start/Multi-Ziel. Heuristik = min-Distanz zu
irgendeinem Ziel-Kandidaten, **ungewichtet** (`f=g+h`). Iterations-Limit 80–85k.
Dynamische Kanten-Aufschläge **nur bei Route-Graph** (`isRouteGraph`-Gate):
Layer-Multiplikatoren (driven 0.86 / autoDrive 0.82 / coursePack 0.88, Z.3328–3426),
Road-Adherence per Terrain-Sample (Z.2507), Korridor-Tightening (Z.2469), Branch-Penalty
für `adFieldBranch` (Z.2626), Turn- (Z.2418) + Continuation-Penalty (Z.2578).
**Beim reinen Spline-Graph greifen diese Guards NICHT** — nur Basiskosten + Endpoint-Snap.

## 5. Endpoint-Snap — `aiRoadFindNodeCandidates` (Z.3071)

Mehrere Kandidaten pro Endpunkt. Radius: Route-Graph 220, AI-Graph 460. Limit 10–12.
Scoring `aiRoadScoreEndpointCandidate` (Z.2972): rawDist + roadBonus(-28) + layer/ad-Penalty
+ Wasser-Penalty(12000) + Connector-Penalty. `aiRoadFilterCandidateComponents` (Z.3020) wählt
die gemeinsame Komponente von Start+Ziel → keine Suche zwischen Inseln.
Connector-Cap: Start 280 / Ziel 320 → sonst ganze Route verworfen.

## 6. Fallback-Reihenfolge — `buildRouteSegment` (Z.5767), exakt

gebündelte WPG-XML (Welt 1) → gescannter AI-Spline-Graph (Welt 2) → Terrain-Farb-A* strict
(`buildRoadBiasedRoute(...,false)`) → Terrain-A* connector/relaxed → **Null-Route** `{start,start}`.
Luftlinie nur intern bei <5 m. Terrain-Farbe formt bei Route-Graph zusätzlich die Kantenkosten mit
(Z.2507), beim reinen Spline-Graph nur den Endpoint-Snap.

## 7. Minimal-Nachbau-Checkliste (reiner Spline-Graph-Router)

`newAIRoadGraph` → `aiRoadNodeIsSafeSplineCandidate` → `aiRoadSplineLength`/`aiRoadSplinePosition`
→ `aiRoadGraphAddNode` (Bucketing) → `aiRoadGraphAddEdge` → `aiRoadGraphAddSpline` (18 m) →
`aiRoadPathLooksUseful` → `aiRoadScanSceneNode`+`aiRoadScanTableForSplines` →
`aiRoadConnectIntersections` (24) → `aiRoadBuildComponents`+`aiRoadStitchNearbyComponents` (58) →
`ensureAIRoadGraph`/`finalizeAIRoadGraph` → `aiRoadFindNodeCandidates`+Scoring+Component-Filter →
`buildAIRoadGraphRoute` (Binärheap-A*). ad*/gpsRoute*-Penalties optional (nur Route-Graph-Qualität).

Engine-Deps: `getSplineLength`, `getSplinePosition`, `entityExists`, `getHasClassId`+`ClassIds.SHAPE`,
`getNumOfChildren`, `getChildAt`, `MathUtil.vector2Length`,
`g_currentMission.{terrainRootNode, rootNode, mapRootNode, trafficSystem, aiSystem}`.

## 8. WPGPS-XML-Graph-Format (`routes/<Map>.wpg.xml`) — direkt nutzbar

```
<WayPointGPSRoadGraph>
  <version>1.0</version>
  <MapName>Helden</MapName>
  <GraphType>WayPointGPS</GraphType>
  <waypoints>
    <id>1,2,3,...</id>          # CSV der Knoten-IDs
    <x>...</x> <z>...</z>        # CSV der Koordinaten (parallel zu id)
    <out>2,404;3;4;...</out>    # je Knoten Nachbarn (',' innerhalb, ';' zwischen Knoten)
    <fieldBranchSeeds>...</fieldBranchSeeds>  # Knoten, die Feld-Einfahrten markieren
  </waypoints>
</WayPointGPSRoadGraph>
```

Parsebar mit ein paar Zeilen Lua/Python. Für die 50 abgedeckten Karten = sofortiger
hochwertiger Routing-Graph ohne eigene Extraktion (Lizenz/Attribution prüfen).
```

## 9. HERKUNFT der Graphen — wer hat sie gebaut, und wie? (belegt)

**Es sind konvertierte AutoDrive-Netze. Menschliche Handarbeit, kein Algorithmus.**

Beweiskette aus dem Code:
- Der XML-Root ist `WayPointGPSRoadGraph.mapmarker.mm<i>` mit `.id/.name/.group`
  (`adReadMapMarkers`, Z.2204) — **1:1 die AutoDrive-`mapmarker`-Struktur**, nur umbenannt.
- `out`-Adjazenz + fehlendes `y`/`incoming` = kompaktiertes AutoDrive-Netz (AD hat x/y/z/out/incoming).
- `fieldBranchSeeds` werden aus AutoDrive-Marker-NAMEN abgeleitet: `adMarkerLooksLikeFieldBranch`
  (Z.2225) matcht `feld/field/hof/silo/bunker/verkauf/unload/wald/...`. Auf Helden bereits
  **offline reingebacken** (die XML trägt keine Marker mehr).
- Registry `WPG_ROUTE_CONFIGS` (Z.136) + Kommentar *"Add more base-map configs here as they are
  prepared"* = manuelle Pflege pro Karte. Author: **plutogaming91**.
- 64 AutoDrive-Bezüge im Code; Live-Import-Pfad `adReadMapMarkers`/`buildWaypointRouteGraph` da.

**Also:** Die FS25-Community fährt für populäre Karten AutoDrive-Kurse von Hand ab (Stunden,
tausende Wegpunkte) und teilt sie. plutogaming91 hat ~50 dieser fertigen AD-Netze ins kompakte
WPGPS-XML konvertiert und gebündelt. Helden = 10.911 Knoten = ein dichtes, von Menschen gebautes
AutoDrive-Netz. **WPGPS' "es folgt dem Feldweg" ist das Abspielen menschlicher Vorarbeit.**

**Konsequenz für NaviHelper:** Dieselbe Quelle ist über `AutoDriveBridge.lua` schon live
erreichbar — wenn AD + ein Kurs für die Karte installiert ist, kann NaviHelper HEUTE darauf routen.
Der Traum "jede Karte, ohne Vorab-Daten, folgt textur-Feldwegen" ist per Algorithmus unerreichbar:
auch WPGPS kann es nicht, es liefert für 50 Karten Handarbeit mit und fällt auf dem Rest zurück.

## 10. AD-Netz-Inventur Markus' Savegames (2026-06-18, gemessen)

AD ist im Standard-Set für alle Karten geladen. Jedes Savegame hat ein `AutoDrive_config.xml`
mit Wegpunkt-Geometrie. **Zwei Sorten Netze:**

- **Auto-generiert aus den AI-Splines** (0 Ziel-Marker): Netzlänge ≈ Spline-Netz der Karte,
  nur Hauptstraßen, KEINE textur-Feldwege. AutoDrive bietet das beim ersten Map-Load an
  ("Netz aus Straßennetz bauen"). **Helden = 12,6 km = exakt das Spline-Netz (~64 %)** → AD
  routet dort auch nur die Hauptstraßen, nicht die Feldwege. Weipersdorf 5,6 km, Die Erinnerung 3 km.
- **Handgebaut / heruntergeladen** (viele Marker): deckt Felder/Höfe mit ab.
  Münsinger Alb 40k WP / Benderspielt · Hinterkaifeck 12,3k / elMatador · Riverbend 123 km /
  20,9k · Pfraunstetten 32k · Hutan Pantai 25k · Oberschwaben 21k · Zielonka 16k · Kinlaig 15k ·
  Pfaffenwinkel 11k. Le Mechet 35 km / Krebach 39 km / Schellenberg 35 km (0 Marker, aber dichtes
  Spline-Netz der Karte → trotzdem gute Abdeckung).

**Pointe:** Helden (Heimat-Map) ist der Worst Case — sein AD-Netz IST nur das Spline-Netz, also
kriegt auch AD-Routing dort die textur-Feldwege nicht. Die existieren nirgends als Daten. Einzige
Wege: die paar Feldwege einmal in AD aufnehmen (Minuten), ODER NaviHelper macht ehrlichen
Luftlinien-Stub aufs Feld. Für 9+ andere Karten liegt das volle Netz schon da → Bridge reicht.
