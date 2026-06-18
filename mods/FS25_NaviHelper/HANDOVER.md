# NaviHelper — Handover & Lessons Learned (2026-06-17)

Übergabe nach einer langen Session. SSoT für den Neustart. Ergänzt `PLAN.md`.

## ⛔ MR. WINSTON WOLF — DEN KNOTEN GELÖST (2026-06-17, abends)

**Die Prämisse "WayPointGPS kann das auf Helden, also können wir das auch" ist FALSCH —
und der Beweis lag die ganze Zeit ungelesen auf der Platte.**

Niemand hat je `tmp/wpgps/routes/Helden.wpg.xml` geöffnet. Gemessen:

- Die Datei ist ein **vorgebauter, handkuratierter Straßengraph**: `<WayPointGPSRoadGraph>`,
  `<MapName>Helden</MapName>`, `<GraphType>WayPointGPS</GraphType>`, **10.911 Wegpunkte**
  mit voller Adjazenz (`out`) + **73 `fieldBranchSeeds`** (Feld-Einfahrten), Spannweite
  1644×1941 m = die ganze Karte. **WPGPS liefert solche Graphen für 50 Karten mit.**
- Zum Vergleich: unser Live-Spline-Scan fand auf Helden **19** Splines, die Bild-Extraktion
  **721** Knoten. WPGPS hat **10.911** — also nicht 5× sondern ~15–575× dichter.

**→ WPGPS folgt dem Feldweg auf Helden NICHT durch Rechnen, sondern durch LADEN
vorgefertigter Daten.** Die im Code reverse-engineerten Live-Methoden (Szenen-Spline-Scan
→ Terrain-Farbe → Luftlinie) sind nur die **Fallbacks für Karten OHNE gebündelten Graph** —
und genau die scheitern auf Helden (unsere Messung Z.323–330 sagte das bereits korrekt).

**Konsequenz für die Abstraktion (Kritiker-Urteil bestätigt):** Textur-only Feldwege haben
kein trennendes Live-Signal (Fingerprints Straße==Acker byte-identisch, Z.33–34). Sie per
Terrain/Tiefe/Farbe zu rekonstruieren ist **beweisbar unlösbar**. Die 6 Terrain-Anläufe
(#3–#8) waren derselbe Grundfehler in 6 Verkleidungen: Topologie (Netzwerk) aus einem
Pixel-Feld raten.

**Die Ziel-Definition kollidiert mit der Physik. Man kann NICHT beides haben:**
- *"folge echten Wegen inkl. textur-Feldwege"* ⟹ braucht **vorgebackene/authored Daten**
  (Bild-Extraktion ODER WPGPS-Graph-Format lesen). Verliert "ohne vorab-Daten".
- *"jede Karte, ohne vorab-Daten"* ⟹ deckt nur das **echte Netz** ab (Splines/Nav-Agent),
  Rest **ehrlicher Luftlinien-Stub**. Verliert volle Feldweg-Abdeckung.

**Empfehlung (mit Zahlen, nicht Vibes):**
1. **Engine-Nav-Agent-Spike** (`createVehicleNavigationAgent`) — nie probiert, Kritiker-Rang 1,
   eine 20-Min-Messung. Endet terminal (Status-Enum, kein "fast"). Trägt auch "fährt selbst".
2. **Parallel: WPGPS-Graph-Format als Quelle erschließen.** `Helden.wpg.xml` ist offenes XML,
   parsebar JETZT. Für die 50 abgedeckten Karten = sofort 10.911-Knoten-Routing in
   Top-Qualität, ohne eigene Extraktion. Lizenz/Attribution klären.
3. **Aufhören**, `openPenalty`/Sättigungs-Schwellen zu drehen. Das ist die belegte Sackgasse.

Empirisch in EINER In-Game-Session zu bestätigen (nur Markus): lädt WPGPS auf Markus' Helden
tatsächlich `Helden.wpg.xml` und folgt es dann dem Feldweg? (bestätigt Pre-Bake-Theorie vor Ort).

Voller RE-Spec der WPGPS-Pfadfindung: siehe `docs/WPGPS_PATHFINDING_SPEC.md` (neu).

## TL;DR — wo wir stehen

Ziel: Fahrzeug zu einem auf der Karte geklickten Punkt routen, **echten Straßen/Wegen
folgend, auf jeder Karte, ohne vorab aufgezeichnete Kurse.**

Der Router (`GreyRouter.lua`) ist ein **Kosten-Gradient-A\*** über ein 3-m-Terrain-Raster.
Zellen werden über **gemessene** Terrain-Signale klassifiziert. Straßen-Folgen funktioniert
richtig gut. **Offenes Problem:** der Router kann textur-only **Feldwege nicht von der Wiese
trennen** → folgt dem konkreten Feldweg nicht.

## Was funktioniert (behalten)

- **Tiefe-Sensor (der Durchbruch):** der **4. Rückgabewert** von
  `getTerrainAttributesAtWorldPos` ist die Boden-Einsink-Tiefe (NICHT Alpha).
  `depth <= 0.1` = befestigte Straße (Basisspiel: `WheelsUtil.getGroundType`).
  Gemessen auf Helden: **91 % der Punkte auf den Straßen-Splines ≤ 0.1 vs. nur 7 %
  des offenen Geländes.** Trennt Straße sauber von Wiese — wo Farbe/materialId versagten.
- **Feld-Ausschluss:** `FSDensityMapUtil.getFieldDataAtWorldPosition`.
- **Kosten-Gradient-A\*:** road billig / open (braune Erde, ×3) / blocked (Feld+Wasser).
  Ziel snappt auf nächste **Straße** (Feld-Klick → Straße daneben). Gewichtetes A\* (W=1.3).
  **Start-Wende-Strafe** (heading-aware, `localDirectionToWorld`) → keine U-Turns am Start.
- Overlay `nhGrey`; Sonden `nhDeep`, `nhTrack`, `nhSurface`, `nhSplines`, `nhProbe*`.

## Gemessene Fingerprints (GOLD — nicht neu messen)

| Ort | depth | mat | rgb | Feld |
|---|---|---|---|---|
| Straße | 0 | 7 | 0.284,0.284,0.284 (grau) | false |
| **Feldweg** | ~0.59 | 1/2 | 0.155,0.082,0.037 (dunkelbraun, sat 0.76) | false |
| Acker | 0.60 | 2 | 0.155,0.082,0.037 (braun) | **true** (terrainDetail bits=14) |

- `g_currentMission.waterY = nil` auf Helden. `environmentAreaSystem` existiert. `getWaterY*`-Globals fehlen.
- **Engine-Nav-Agent-API VORHANDEN:** `createVehicleNavigationAgent`,
  `setVehicleNavigationAgentTarget`, `getVehicleNavigationAgentNextCurvature`. navMap-Handle gültig.
- 19 `aiSystem.roadSplines`, 12,6 km, ~64 % Kartenabdeckung.

## Was wir getestet haben — und warum es scheiterte

1. **Bild-Extraktion** aus `overview.dds` → Straßen-Skelett-Graph. *Verworfen:* karten-
   autor-abhängiger Stil, Kalibrierungs-Hölle (~174° Rotation), nicht generalisierbar.
2. **Nur `aiSystem.roadSplines`** (12,6 km): deckt Dorfstraßen/Feldwege angeblich nicht ab
   (textur-only auf Helden — **UNVERIFIZIERT, s. u.**).
3. **`getIsPositionReachable`:** 92 % „reachable", zu grob als Drivability-Orakel.
4. **Terrain-FARBE (grau/tan, WPGPS-Stil):** Straße == Wiese == grau auf Helden → flutet
   oder verfehlt. Wasser/trockenes Gras in derselben Farbfamilie.
5. **materialId-Set aus Splines:** mat 7 ist die **ganze** Nicht-Feld-Karte → flutet alles.
6. **Surface-Name (`materialIdToSurfaceSound`):** Tabelle auf Helden nicht vorhanden.
7. **depth + Braun-Farbe:** löst Straße-vs-Wiese. ABER braune Erde ist überall *unter* dem
   Gras → Feldweg nicht von Bankett/Wald/Wiese trennbar → flutet Grün, oder (mit Kosten-
   Gradient) schneidet quer durchs Grün statt dem Weg zu folgen.
8. **Kontinuität/Korridor (WPGPS-Port):** half wenig, knackte Weg-vs-Bankett nicht.

## Das eigentliche ungelöste Problem

Feldweg (befahrbare Erd-Spur) und Wiese/Bankett/Wald liegen auf **derselben braunen Erde**,
nur unterschiedlich bewachsen. Terrain-Sondierung (Tiefe, Farbe, Material) kann sie nicht
trennen. Das einzige trennende Signal ist **Gras-Bewuchs** (Weg = kahl, Wiese = Gras).
`terrainDetailHeightId` war überall 0 (falscher Layer). **Noch ungelesene Foliage-Quellen:**
`foliageSystem`, `dynamicFoliageLayers`, `mapGrassFieldColor`, `g_densityMapHeightManager`.

## Markus' Einwand: „wenn WayPointGPS das auf dieser Map kann, können wir das auch"

**Er hat recht — und hier ist der blinde Fleck:** Wir haben WayPointGPS **nie auf Helden
laufen lassen und zugeschaut.** Wir haben den Code reverse-engineered, aber nie empirisch
gesehen, ob/wie WPGPS dem Feldweg folgt.

WPGPS' **echte** Methoden-Priorität (aus `tmp/wpgps/scripts/WayPointGPS.lua`):
1. **AutoDrive-Routen-Graph-Import** (`WayPointGPSRoadGraph.mapmarker`-XML), falls AD-Netz da.
2. **Selbstgebauter SPLINE-Graph:** scannt `trafficSystem` + `aiSystem` + Szenen-Wurzeln
   (`terrainRootNode`/`rootNode`/`mapRootNode`) nach **allen Spline-SHAPES** (nicht nur
   `aiSystem.roadSplines`!), sampelt sie, baut einen Bucket-Knoten-Graph, A\* darauf.
3. Terrain-Farbe (der Teil, der auf Helden scheitert).
4. Luftlinie.

→ **WPGPS ist primär ein Spline-Graph-Router.** Wir haben nur `aiSystem.roadSplines` (19)
gemessen und Splines dann verworfen. Wir haben womöglich Terrain gejagt, obwohl die Antwort
**Splines** heißt. Genau das hat der Kritiker gewarnt („du hast die eine solide Datenquelle
verworfen, weil sie nicht 100 % war").

## DIE entscheidenden nächsten Schritte (frische Session)

1. **EMPIRISCH zuerst:** WayPointGPS auf Helden aktivieren, zum selben Feldweg-Ziel routen,
   **zuschauen.** Folgt es dem Feldweg? WPGPS-Logging an — **welche Methode feuerte**
   (AD-Import / Spline-Graph / Farbe)? Dieser eine Test beendet alle Spekulation.
2. **Wenn Spline-Graph:** unser `nhSplines` (voller Szenen-Graph-Scan) erneut laufen lassen
   und mit WPGPS' `buildAIRoadGraph` vergleichen. Wir haben evtl. unterzählt (nur
   `aiSystem.roadSplines`). Dann **Spline-Graph-Router bauen** (Kritiker-Rang 1).
3. **Wenn AutoDrive-Kurs auf der Map:** auf AD-Config der Karte prüfen.
4. **Wenn WPGPS wirklich nur Farbe nutzt und folgt:** seine `classifyRoadCellDetailed`
   exakt re-diffen — wir haben ein Detail übersehen.
5. **Parallel — Foliage-Jagd:** `foliageSystem`/`dynamicFoliageLayers`/
   `g_densityMapHeightManager` lesen (NICHT `terrainDetailHeightId`), um Wege als kahl zu markieren.
6. **Engine-Nav-Agent** (`createVehicleNavigationAgent` …): die Engine über ihre Road-Costmap
   routen/fahren lassen. Anders als Linie-malen — könnte „Helfer fährt selbst" tragen.

## Schlüssel-Commits (diese Session)

`b81f421` depth-Sensor · `4eea87f` +Braun · `bf6447c` Kosten-Gradient-A\* ·
`0558acd` Ziel-Snap-auf-Straße + gewichtetes A\* · `28e75e9` openPenalty 60→3 ·
`4535153` Start-Wende-Strafe.

## Dateien

- `scripts/GreyRouter.lua` — Router (depth+Braun-Sensor, Kosten-Gradient-A\*, Snapping, Start-Wende).
- `scripts/RoadStats.lua` — Sonden: `nhDeep`, `nhTrack`, `nhSurface`, `nhSplines`, `nhProbe*`, `nhRoadStats`.
- `scripts/NaviHelper.lua` — Haupt (Karten-Klick, Overlay `nhGrey`, Route-Bau, dynamisches Reroute, Heading).
- `tmp/wpgps/scripts/WayPointGPS.lua` — Referenz-Impl (für die Spline-Graph-Methode LESEN).

## Lessons (Mr. Winston Wolf)

- **Messen schlägt Raten** (`nhDeep`/`nhTrack` waren die Wendepunkte).
- **Eine Referenz nicht nur reverse-engineeren — sie LAUFEN lassen und zuschauen** (der WPGPS-Fehler).
- Terrain-Aussehen ≠ Topologie; eine Straße ist ein Netzwerk, keine grauen Pixel.
- Helden ist die **Worst-Case-Testkarte** (mat 7 überall, keine Surface-Namen, textur-only
  Wege, tote Wasser-API). Auf einer zweiten Karte gegenprüfen.
- Und: rechtzeitig einen Schnitt machen. Diese Session war zu lang — Markus hat's gemerkt,
  bevor SAM es tat. 😉
