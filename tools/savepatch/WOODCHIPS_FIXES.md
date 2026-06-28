# FS25_woodChipsMission — personal fork patches (htModding mod)

Map-/Mod-Inkompatibilität auf **Weipersdorf**: Hackschnitzel-Transport-Aufträge ("HOLZHÄCKSEL-TRANSPORT")
haben Lieferungen nicht angerechnet. Über mehrere Sessions seziert und mit 5 idempotenten Patches gefixt
(2026-06-28). Der Mod hat **kein öffentliches Repo** (Autor htModding) → Eigen-Fork, nach jedem Mod-Update
neu einspielen.

## Symptom

Du lieferst Hackschnitzel an die "Scheune VK" (Missionsziel), bekommst Geld, aber `Geliefert` bleibt 0.
Drei Aufträge (Feld 139/108/102), alle auf dieselbe Station gelockt, alle bei 0 %.

## Die Bug-Kette (von außen nach innen)

1. **Reload verliert die Station.** Nur `sellingStationId/Name/Ziel-Koordinaten` werden gespeichert, nicht das
   Live-`sellingStation`-Objekt. Nach dem Laden ist es `nil`; die Lazy-Auflösung ist unzuverlässig.
2. **`_isTargetStation` bricht bei `sellingStation == nil` hart ab** → das Anrechnen (`fillSold`) feuert nie,
   obwohl Vanilla dich auszahlt. → `depositedLiters=0`, `wrongStationLiters=0`.
3. **Die Reload-Auflösung überschreibt die echten Ziel-Koordinaten** mit denen einer falsch/fern aufgelösten
   Station ("Selling Station").
4. **`saveToXMLFile` crasht bei jedem Speichern** (`setXMLString`: `#sellingStationName` ist `nil`, weil
   `sellingStation` nil ist).
5. **Die Scheune zahlt über `Mission00:addMoney` direkt** — ganz ohne `sellFillType`. Damit greift der reguläre
   Sell-Hook nicht, und der addMoney-Fallback des Mods findet "no pending".
6. **Der addMoney-Inferenz-Fallback scheitert an der Nähe-Prüfung:** Spieler-Tip-Position ≠ gespeicherte
   Ziel-Koordinaten (auf dieser Map sind Stations-Wurzel und Entlade-Trigger > 160 m auseinander) → kein
   Kandidat → kein `fillSold`, nicht mal ein Ergebnis-Log.

## Die Patches (in dieser Reihenfolge, alle idempotent)

| Skript | Datei | Fix |
|---|---|---|
| `patch_woodchips_reload_credit.py` | WoodChipsMission.lua | `_isTargetStation` matcht zusätzlich über die **gespeicherten Ziel-Koordinaten** (25 m) → Anrechnen reload-fest. |
| `patch_woodchips_target_coords.py` | WoodChipsMission.lua | (a) Save-Crash-Guard (`#sellingStationName` Fallback), (b) Reload-Retry überschreibt gültige Ziel-Koordinaten nicht mehr. |
| `patch_woodchips_rollover.py` | WoodChipsMissionRegister.lua | Überschuss einer Lieferung rollt über **alle** Aufträge der Station (Vanilla-Erntejob-Verhalten); nur echter Rest zahlt Markt. |
| `patch_woodchips_inference_proximity.py` | beide | addMoney-Inferenz-Nähe über gespeicherte Ziel-Koordinaten; `serverOnWoodchipsSold` vertraut der **eigenen** Mission-Station. |
| `patch_woodchips_first_mission.py` | WoodChipsMissionRegister.lua | **DER entscheidende Fix:** Nähe-Logik ganz umgangen — bei ≥1 offenem Auftrag an der Station dem **ersten liefernden** gutschreiben (Verteilung folgt von selbst) + Preis-Fallback auf den gespeicherten Missionspreis. |

### Nach einem Mod-Update neu einspielen

```sh
cd ~/Dropbox/htdocs/FS25_Mods/tools/savepatch
# FS muss zu sein
for p in reload_credit target_coords rollover inference_proximity first_mission; do
    python3 "patch_woodchips_${p}.py" --apply
done
~/Dropbox/htdocs/FS25_Mods/tools/fsmods/fsmods use weipersdorf
```

Jedes Skript ist idempotent (Marker-Kommentar `-- [SAM patch] ...`), legt einmal ein `.bak_*` an und tauscht
nur das eine Member im Zip. Bricht sauber ab, wenn ein Anker (durch ein Mod-Update) nicht mehr passt.

## Lessons Learned

- **Bei Laufzeit-Verhalten zuerst den echten Trace holen, nicht auf statischem Code-Lesen patchen.**
  Fünf Patches gingen auf Teil-Lesungen — erst das **erzwungene Debug-Logging** (beide Flags fest im Zip)
  zeigte die wahre Lücke (die Nähe-Prüfung war immer `false`). Der 6. Versuch saß. → Mr-Winston-Wolf:
  messen, dann schrauben.
- **Mod-Debug kann doppelt verdrahtet sein:** `wcSetDebug` setzte nur *ein* Flag, die Detail-Logs hingen am
  anderen. Konsolen-Befehle täuschen "Debug an" vor, ohne dass die relevanten Zeilen schreiben. Im Zweifel
  beide Flags hart auf `true` ziehen (temporär), Trace holen, danach zurückbauen.
- **Objekt-/Nähe-basierte Zuordnung ist fragil.** Stations-Auflösung nach Reload, Stations-Wurzel ≠
  Entlade-Trigger, addMoney ohne Fülltyp-Info — robuster ist Zuordnung über **stabile gespeicherte Daten**
  (Ziel-Koordinaten, „braucht noch Lieferung").
- **Luau-Falle:** `_` als Wegwerf-Variable ist const ("attempt to assign to const variable '_'"). Benannte
  Locals nehmen.
- **Vor dem Eigen-Fork das Mod-Repo checken.** Bei Fields of Stories hatte der Autor den Bug schon gefixt
  (nur Update nötig). woodChipsMission hat kein öffentliches Repo → Eigen-Fork war der einzige Weg.
- **Jeden Fix als reproduzierbares, idempotentes Skript** ablegen — bei self-maintained Mods unverzichtbar,
  weil jedes Update die Patches überschreibt.
