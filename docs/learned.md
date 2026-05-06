# Lessons Learned

Tips, references, and lessons from FS25 mod development (e.g. FS25_NaviHelper).

---

## Architecture / event chain

- **onDrawUIInfo** is the main entry for HUD drawing. If the engine never calls it for your vehicle spec, nothing is drawn. Fallback: in the mod’s **draw()**, when `controlledVehicle` and `navAidOn` are set, call **drawForVehicle(controlledVehicle)** so drawing still works if onDrawUIInfo is never fired.
- **Coordinates:** GDN uses **bottom-left origin** for text. High y (e.g. 0.88) = top of screen; for the lower area use low y (e.g. 0.1–0.15).

## Debugging

- **Fewer restarts:** Instead of hunting through log.txt, write a **single diagnostic file** on one action (e.g. when pressing Alt+N with no target): dump vehicle, AutoDrive state, marker, waypoints, getSelectedDestination. Copy that file into the project once and fix from it.
- **Throttled logging:** In hot paths (onDrawUIInfo, drawForVehicle), log at most every N seconds to confirm the chain runs and where it breaks.
- **File logging from game Lua:** When writing NDJSON or diagnostic files from mod scripts (e.g. `io.open(path, "a")`), the game may run in a sandbox or different working directory, so the file might not be created or written at the expected path. FS25 may also restrict `io.open` modes (e.g. append unavailable). **Fallback:** Use `Logging.info()` so the game’s `log.txt` receives the same data; rely on log.txt when session-specific log files are empty or not appendable.

## AutoDrive integration

- Destination: **getSelectedDestinationFromVehicle(vehicle)**. Route: **drivePathModule.wayPoints** (active drive) or **stateModule.firstMarker** (destination only). Path computation: **NaviHelperAD.getPathFromToWorld(vehiclePos, dest)**.

## Route line (3D)

- **ADDrawingManager:addLineTask** (AutoDrive): in our use the manager’s lines were **cleared every frame** → flicker only. **Fix:** Load AutoDrive’s **asset** (e.g. `drawing/line.i3d`) and create **our own** segment nodes under our root (e.g. `g_currentMission.terrainRootNode`); then nothing else clears our line.
- **drawDebugLine** is a debug API, not a documented “mod line” API; OK as a pragmatic fallback for release, but not the intended long-term solution.
- Proper approach: own **I3D segment** (e.g. in GIANTS Editor), load once, pool of segments, update position/rotation each frame – our nodes are not cleared by others.

## UX (FS mod convention)

- Control via **key bindings** (Settings → Controls), not by clicking HUD elements. NaviHelper stays off until the user presses the toggle key (e.g. Alt+N).

## Cruise Control (FS25_CruiseControlPlus)

- **TOGGLE_CRUISE_CONTROL handler:** GDN and forums do not document which Drivable method is bound to KEY_3. In FS25, `_G.Drivable` has no `actionEventToggleCruiseControl` but has `actionEventCruiseControlState` and `actionEventCruiseControlValue`. By naming convention, **State** = on/off (toggle), **Value** = speed (KEY_1/KEY_2). We hook `actionEventCruiseControlState` and verify at runtime: if pressing KEY_3 produces "WRAPPER CALLED" in the one-shot diagnose file, the hook target is correct.
- **controlledVehicle vs. vehicle in action events:** When you wrap a vehicle action event (e.g. `Drivable.actionEventCruiseControlState`), the callback receives the vehicle as first argument; that vehicle is the one the player is controlling. Do **not** require `g_currentMission.controlledVehicle == vehicle` to run your logic: at action-event call time, `controlledVehicle` can be nil or a different reference (observed: `controlledSame=false` in diagnose while the wrapper was correctly invoked for the active vehicle). Use `vehicle:getIsControlled()` if you need to confirm the player is in control; otherwise trust the vehicle argument.
- **KEY_3 / cruise handler not called (class hook):** Overwriting `Drivable.actionEventCruiseControlState` can fail if vehicle types or specs already hold the original function reference at load time. **Fix:** Wrap per vehicle in your specialization’s `onRegisterActionEvents(_, isOnActiveVehicle)`: when `isOnActiveVehicle` is true, replace `self.actionEventCruiseControlState` with a wrapper that runs your logic and optionally calls the original. Then KEY_3 is guaranteed to hit your code for the active vehicle (same pattern as other mods that extend vehicle input).
- **Vehicle speed for display / cruise:** Use multiple sources in order: `vehicle.lastSpeed`, then `vehicle.spec_motorized.motor.lastSpeed`, then `vehicle:getLastSpeed()`. Cruise speed in engine is integer (UInt8 in stream); use math.floor(kmh+0.5). Send SetCruiseControlSpeedEvent / SetCruiseControlStateEvent so UI/network see changes.
- **Speed at action-event time:** When reading speed inside an input action callback (e.g. “set cruise to current speed”), `lastSpeed` and `motor.lastSpeed` are often **nil or 0** in that frame (update order). Rely on **getLastSpeed()** as fallback so “Speed too low” does not appear when the player is actually driving.
- **getLastSpeed() unit in FS25:** In practice `vehicle:getLastSpeed()` returns **km/h** in FS25 (not m/s as in GDN). If you multiply by 3.6, cruise target is ~3.6× too high. **Track which source provided the value:** use raw value as km/h when source is `getLastSpeed`, and `speed * 3.6` only for `lastSpeed` / `motor.lastSpeed` (m/s).

## Controls Search (FS25_ControlsSearch) – Spike

- **Spike mod:** `mods/FS25_ControlsSearch`. When in game, open Options → Controls and press **F**. Check `log.txt` for `[ControlsSearch]` lines: spike dumps `g_gui` keys (to detect controls screen) and `g_inputBinding` structure (e.g. `nameActions`).
- **Add findings here after a run:** e.g. how to detect "controls screen" (which `g_gui` field or screen name), and how to iterate all actions/bindings (tables, method names). Use Logging.info for dump; file writes from game Lua may not land in project dir.

## Mouse Steering (FS25_MouseSteering_MiddleClick)

- **Look vs. steering:** Unterdrücke Kamera/Mirror nur bei `armed AND active` (LMB gehalten). Bei `armed` allein: Maus (ohne LMB) muss weiterhin den Look links/rechts steuern. Unterdrückung nur auf `armed` blockiert den Umblick komplett.
- **Kurvenblick + Coast:** Zusätzliches Kamera-`rotY` nach `VehicleCamera:update`; aktiv während `active` oder `_steeringCoast`, solange nicht Frontlader-Zweig selektiert (s.u.). Coast: nach LMB-Loslassen exponentieller Zerfall von `steeringValue`, gekoppelt an Spiel-Lenkrückstellung (`GameSettings`-Namen per Kandidatenliste + Fallback-Prozent).
- **Frontlader vs. Maus:** Kein globales Auto-Disarm mehr. Teilbaum per **Joint-Typ** am Root (`attacherJoints` → Typname enthält `frontloader`) per DFS plus **Union** mit `getAttachedImplementsInfo().frontLoaders` (JD / Sonder-XML). Selektion: `getSelectedVehicle()` und zusätzlich `getSelectedImplement()` — wenn deren `.object` im Teilbaum: Mod-Maus pausieren.
- **Frontloader hydraulics vs. LMB steering (cab focus):** Use **two layers**. (1) Keep zeroing axis-like keys in `spec_*`.`lastInputValues` on objects in the frontloader hardware subtree (`VehicleIntrospection:zeroMouseHydraulicAxesOnFrontloaderHardware`), called from vehicle `onPostUpdate` and mission `draw`. That path alone was **not sufficient** in FS25 — some fork/arm motion still followed mouse steering because vanilla feeds **bound action callbacks**, not only those tables. (2) Additionally, each frame while LMB steering should suppress loader input, **`MouseSteeringVehicle:onPostUpdate`** wraps the vanilla handlers for **`AXIS_FRONTLOADER_ARM`**, **`AXIS_FRONTLOADER_TOOL`**, and **`AXIS_FRONTLOADER_TOOL2`** inside `g_inputBinding.actionEvents`: include rows whose `targetObject` is the controlled vehicle **or** any implement/table whose `rootVehicle` or `getRootVehicle()` equals that vehicle (tractor rows alone miss `attachableFrontloader` / `implementDynamicMountAttacher` targets). Suppress only when `armed` ∧ `active` ∧ no frontloader-branch selection ∧ not LMB+RMB free-look (`MouseSteering._otherMouseButtonDown`).
- **InputBinding replaces callbacks after implement selection changes:** After cycling tractor ↔ trailer ↔ loader ↔ fork, the engine may **replace `ev.callback`** on existing action-event rows. A permanent “already wrapped” dedupe keyed only by event identity **without** checking the current function pointer lets suppression silently stop. Pattern that works: mark **only** your wrapper functions in a **weak-key** table (`setmetatable({}, { __mode = "k" })`); before wrapping, if `ev.callback` is not marked, wrap the **current** function again (see mod: `_flWrapMarkers` on `MouseSteeringVehicle`).
- **Cylindered / spec `actionEventInput` class hooks:** Hypothesis that wrapping `Cylindered.actionEventInput` on specialization classes resolves the same mouse bleed proved **not actionable** in this runtime (no stable vehicle/spec method hit compared to live `actionEvents` evidence). Prefer **`g_inputBinding.actionEvents`** when diagnosing axis-driven tools.
- **Mod actions in Settings → Steuerung:** Actions aus modDesc erscheinen in den Spieloptionen, wenn l10n-Einträge mit `input_ACTION_NAME` in den l10n-Dateien existieren (z.B. `input_MOUSESTEERING_OPEN_SETTINGS`). Ohne diese Einträge funktioniert die Registrierung zwar (actionId gefunden), aber das Label kann fehlen oder die Action unsichtbar wirken.

## Game Settings UI erweitern (eigene Gruppe im Allgemein-Tab)

Belegte Praxis in zwei unabhängigen FS25-Mods: **FS25_ContractBoost** (mit `scripts/lib/UIHelper.lua` von Farmsim Tim / Shad0wlife, zur freien Weiterverwendung) und **FS25_LumberJack** (`LumberJackSettings.lua`, gleiche Technik ausgerollt).

- **Einhängepunkt:** `g_gui.screenControllers[InGameMenu].pageSettings`. Dort sitzen `generalSettingsLayout` (Layout-Container), `controlsList` (Liste für Focus-Manager), sowie bereits existierende Controls, die als Clone-Templates dienen.
- **Clone-Templates:** `pageSettings.checkWoodHarvesterAutoCutBox` für Bool-Switches, `pageSettings.multiVolumeVoiceBox` für numerische Ranges und Choice-Listen. Section-Header per Iteration über `generalSettingsLayout.elements` bis `elem.name == "sectionHeader"` finden und klonen.
- **Wichtig, sonst kaputt:** Nach `clone()` ALLE Focus-IDs per `FocusManager:serveAutoFocusId()` neu vergeben (rekursiv über Kinder). Und der `target` eines eigenen Control-Callback-Handlers braucht `target.name = settingsPage.name`, weil der FocusManager sonst Controls mit abweichender `target.name` ignoriert.
- **Populate-Hook:** `InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, fn)` — wird beim Öffnen der Settings gefeuert, hier eigene Controls aus dem Settings-Objekt befüllen (setState).
- **Focus-Manager-Hook:** `FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, fn)` — in der Function eigene Controls via `FocusManager:loadElementFromCustomValues(control, nil, nil, false, false)` registrieren und anschließend `settingsPage.generalSettingsLayout:invalidateLayout()`. Ohne diesen Schritt funktionieren Pfeiltasten / Controller-Navigation nicht.
- **Frame-Klassenname:** Der relevante Frame ist `InGameMenuSettingsFrame`, **nicht** `InGameMenuGeneralSettingsFrame` (letzterer existiert in FS25 so nicht).
- **l10n-Konvention des UIHelper:** Pro Control zwei Keys: `<prefix>_<name>_short` (Titel) und `<prefix>_<name>_long` (Tooltip). Callback-Namen: `on_<name>_changed` auf dem `owningTable`.
- **Lizenz-Hinweis UIHelper.lua:** Header sagt *"You may change anything except for the first three lines"* — also freie Nutzung mit Attribution (erste drei Zeilen unverändert lassen).
- **Falle — owningTable vs targetTable müssen getrennt sein:** `UIHelper.createControlsDynamically` schreibt die erzeugten Control-Objekte nach `owningTable[controlProps.name] = uiControl`. Wenn man (wie intuitiv) dieselbe Tabelle für Settings-Werte und UI-Controls benutzt, werden die numerischen Werte von Control-Objekten überschrieben. Folge: `setXMLFloat: Argument 2 is Table` beim Speichern, und Vergleiche wie `math.abs(out) < deadzone` crashen zur Laufzeit. Fix: zwei Tabellen. Werte-Tabelle als `targetTable`, UI-Halter-Tabelle (mit `.controls = {}`) als `owningTable`.

## l10n in FS25

- **Inline + extern, sonst greift's nicht:** Ein `<l10n filenamePrefix="l10n/l10n"/>` self-closing in modDesc mit Einträgen nur in externer `l10n/l10n_<lang>.xml` reicht FS25 nicht: die externen Keys werden schlicht nicht aufgelöst und die UI zeigt `Missing 'key_name' in l10n_de.xml`. Bewährtes Pattern (NaviHelper, anderer Mods): die Keys **doppelt** pflegen — inline in modDesc innerhalb `<l10n>…</l10n>` (nicht self-closing), zusätzlich in externen `l10n_<lang>.xml`. Dann klappt's.
- **l10n-Cache:** Änderungen an modDesc oder externer l10n greifen erst nach komplettem Spiel-Neustart (nicht nur Welt verlassen).

## Vehicle introspection

- **Size: Subtable statt Flache-Attribute:** Bei neueren FS25-Fahrzeugen und insbesondere **allen Implements** (Anhänger, Frontlader etc.) liegen die Dimensionen in `vehicle.size = { length, width, height }`. Die flachen `vehicle.sizeLength` / `vehicle.sizeWidth` sind oft nicht gesetzt. Defensiver Zugriff: Subtable zuerst probieren, dann flache Felder als Fallback.
- **Specs sind Metatable-vererbt, NICHT via `pairs()` sichtbar:** Ein `pairs(vehicle)` listet nur Instance-Level-Attribute. Die `spec_wheels` / `spec_attachable` / `spec_attacherJoints` etc. existieren, werden aber über Lua-Metatable an der Instanz angeboten. Richtig: direkte Probe mit `vehicle.spec_wheels` statt Iteration. Für Discovery: Liste bekannter Spec-Namen durchprobieren.
- **getTerrainHeightAtWorldPos-Signatur ist 4-Arg:** `getTerrainHeightAtWorldPos(terrainNode, x, y, z)` — der `y`-Parameter ist Input-Placeholder und wird für die Höhenabfrage ignoriert. 3-Arg-Aufruf (ohne y) führt zu `Function called with invalid number of arguments. 3 instead of 4` bei JEDEM Frame. Als terrainNode funktioniert `g_terrainNode` (canonical) oder `g_currentMission.terrainRootNode`.
- **Vehicle-Local +X zeigt nach LINKS (Giants-Engine-Konvention):** Intuitiv würde man meinen +X = rechts des Fahrzeugs, aber die Vehicle-rootNodes in FS25 orientieren +X nach links. Beim Transform von vehicle-lokalen Pfadpunkten ins Weltframe via `localToWorld` muss X negiert werden, damit Rechtslenkung den Pfad nach rechts zeichnet.
- **Lenkeinschlag-Quelle je Input-Typ:** `vehicle.spec_drivable.lastInputValues.axisSteer` wird nur gefüllt, wenn unser eigener Mauslenk-Code reinschreibt. Bei Tastatur-A/D, Controller und Lenkrad läuft der Wert über einen anderen Pipeline-Pfad. Robust: `vehicle.rotatedTime / vehicle.rotatedTimeMax` — das ist der physische Rad-Winkel nach vollständiger Input-Verarbeitung, normalisiert auf [-1, 1]. Funktioniert für alle Input-Quellen. Fallback-Kaskade: rotatedTime → spec_drivable.axisSide → lastInputValues.axisSteer.
- **Max-Speed für Fahrzeug-spezifische Skalierungen:** Kandidaten in Reihenfolge: `vehicle:getCruiseControlMaxSpeed()` (km/h), `spec_motorized.motor.maxForwardSpeed` (m/s → *3.6), `spec_drivable.cruiseControl.maxSpeed` (km/h). Default 40 km/h (Mid-size Tractor), clamped auf 10–300. Relativ-Skalierung ist immer besser als absolute Konstanten — ein 40-km/h-Traktor bei Vollgas soll dasselbe relative Verhalten bekommen wie ein 80-km/h-LKW bei Vollgas.

## Action-Events und Input

- **Nicht mehrere Trigger-Pfade für dieselbe Action:** Wenn eine Action via `modDesc.xml`-Binding automatisch an ein Action-Event gekoppelt ist UND zusätzlich per `keyEvent`, `update()`-Polling oder `mouseEvent` abgefragt wird, feuert die Logik mehrfach pro Tastendruck. Bei Toggle-Handlern heben sich die Toggles gegenseitig auf — fällt auf, wenn der Ausgangszustand variiert (z.B. `armed=false` vs `armed=true` beim Einsteigen). Regel: **single source of truth pro Action**. Wenn eine Action als Action-Event registriert ist, die keyEvent/Polling-Pfade entfernen.
- **HelpIconBox-Eintrag:** Nach `InputBinding.registerActionEvent(...)` den Rückgabewert `eventId` speichern und `g_inputBinding:setActionEventTextVisibility(eventId, true)` setzen. Dann erscheint die Action mit ihrem l10n-Label in der Vanilla Help-Icon-Box oben links (solange der Spieler im Fahrzeug ist).
- **Action-Event-Callback-Signatur:** `registerActionEvent(g_inputBinding, actionId, self, callbackFn, triggerUp, triggerDown, triggerAlways, isActive)`. Der Callback wird als `callbackFn(self)` aufgerufen — `self` ist das Vehicle-Objekt, an dem die Spec hängt.

## Attached implements

- **`vehicle.spec_attacherJoints.attachedImplements`** ist ein Array der aktuellen Anbaugeräte. Jeder Eintrag hat `.object` (= das Implement-Vehicle-Objekt) und `.jointDescIndex`. Der Joint-Typ steht im Host-Fahrzeug unter `spec_attacherJoints.attacherJoints[jointDescIndex].jointType` — **als Integer-ID**, nicht als String.
- **`AttacherJoints.jointTypeNameToInt`** ist ein string→int Mapping. Reverse-Lookup (int → name) liefert lesbare Bezeichner: 2 = "trailer", 7 = "frontloader" (bei manchen Varianten), 12 = "frontloader" (bei anderen).
- **Frontlader-Erkennung:** via Joint-Type-Name (`frontloader`) ODER Vehicle-Type-Name (Substring `frontloader` / `loader` / `attachableFrontloader`). Robuste Fallback-Kaskade.
- **Anhänger-Drehschemel-Heuristik:** `#vehicle.components > 1` ist ein gutes Indiz. Einachs-Anhänger haben typischerweise 1 Component, Zweiachser mit Drehschemel 2+.
- **Cache-Key muss Object-Identities enthalten:** Ein einfacher Count-basierter Cache (`#attachedImplements`) versagt beim Anhänger-Swap (A ab, B dran = gleicher Count, anderes Object). Besser: `table.concat({tostring(impl.object) for impl in attached}, "|")` als Cache-Key.

## Trailer kinematics (rückwärts-Simulation)

- **Kingpin-Hitch-Modell (single-track bicycle-trailer):** Für jeden Simulationsschritt: (1) Hitch bewegt sich entlang Zugfahrzeug-Pfad, (2) Anhänger-Achse rollt **nur in ihrer momentanen Längsrichtung** (Rollbedingung, keine Seitengleitreibung), also Verschiebung = Projektion von Hitch-Delta auf Trailer-Forward-Vektor, (3) Soft-Constraint: Achse auf Kreis mit Radius `tongueLength` um neuen Hitch projizieren — hält die Deichsel rigide.
- **Knickwinkel live messen, nicht annehmen:** `localToLocal(trailerRootNode, vehicleRootNode, 0, 0, 0)` und zusätzlich `(..., 0, 0, 1)` gibt Position und Forward-Richtung des Anhängers im Zugfahrzeug-Frame. Knickwinkel = `atan2(dx, dz)` auf dem Forward-Vektor. Die Simulation sollte bei diesem Live-Winkel starten, sonst stimmt sie nicht mit der tatsächlichen Anhängerstellung überein.
- **Deichsel-Länge aus Anhängerlänge approximieren:** Einachser: Achse ≈ 65 % der Gesamtlänge vom Hitch. Zweiachser mit Drehschemel: Hinterachse ≈ 80 % der Länge vom Hitch. Exakte Achsenpositionen aus `spec_wheels` hätten vorrang, sind aber in der Praxis bei Implements oft nicht zugänglich (loadingState-abhängig); die Approximation ist gut genug für Visualisierung.
- **Settings-Toggle sinnvoll als Bool, nicht als Dropdown:** Anhänger-Pfad macht nur bei Rückwärtsfahrt Sinn, der Rest (Feature an/aus) ist binary. Ein einzelner Bool-Toggle "Anhänger-Pfad (Rückwärts)" reicht.

## Rendering: mehrere Linien-Gruppen mit verschiedenen Farben

- **I3D-Pool teilen statt parallele Pools:** Der SegmentPool-Ansatz skaliert auf N Linien-Gruppen einfach, indem man pro Gruppe einen Farb-Parameter durch den Render-Loop zieht und alle Gruppen sequenziell in denselben Pool rendert. Unbenutzte Nodes am Ende `setVisibility(false)`. Performance-mäßig kein Problem, solange MAX_SEGMENTS ausreichend dimensioniert ist (80 = reichlich für 2 × 2 Linien à 20 Segmenten).
- **drawDebugLine-Fallback muss Farbe pro Segment speichern:** Im Single-Group-Fall kann eine globale `debugColor` durchgezogen werden; im Multi-Group-Fall wird die Farbe pro Segment mit-persistiert (extra Felder im Segment-Array). Zwei separate Code-Pfade (`_applyDebug` vs `_applyDebugMulti`), aber nicht komplex.
- **State-Hygiene-Falle bei Multi-Mode-Code:** Wenn Multi-Mode-Render-Code zwischen "single colour" und "per-segment colour" umschaltet, MUSS jeder Mode-Pfad das gegenseitige Modus-Flag explizit zurücksetzen. Konkretes Symptom in unserem Fall: nach einer Rückwärts-mit-Anhänger-Runde (multi mode) blieb `debugMulti=true` stehen; bei der nächsten reinen Vorwärtsfahrt (single mode) war das Flag noch true, der Multi-Drawer las `seg[7..9]` als Farbe, fand `nil` und crashte stillen pcall-Spam pro Frame — ergo: keine Linien sichtbar. Lehre: bei jedem Mode-Eintritt explizit das jeweilige Flag setzen, nicht nur beim Verlassen.

## g_inputBinding internals (FS25)

Diese Erkenntnisse stammen aus dem RMB-Suppression-Subprojekt. Fasse sie hier zusammen, weil sie auch für andere "in den Input-Pfad eingreifen"-Aufgaben relevant sind.

- **Struktur von `g_inputBinding.actionEvents`:** 2-Level-Tabelle. Outer-Key ist *nicht* eine Integer-ID, sondern die **Action-Definition selbst** (eine Lua-Tabelle, deren `tostring()` etwa `"[ACTION_NAME: categories= 1, axisType=HALF, isLocked=true]"` ergibt). Innerer Wert ist ein Array von Event-Tabellen. `g_inputBinding.nameActions[name]` liefert ebenfalls dieses Action-Definitions-Objekt, nicht eine Zahl. Wer mit numerischen IDs rechnet, sucht ins Leere.
- **Iterations-Pattern:** 
  ```lua
  for name in pairs(targetNames) do
      local actionObj = g_inputBinding.nameActions[name]
      local list = actionObj and g_inputBinding.actionEvents[actionObj]
      for _, ev in ipairs(list or {}) do ... end
  end
  ```
- **Nicht alle Bindings haben registrierte Action-Events:** Eine Action kann in `inputBinding.xml` an eine Taste gebunden sein und trotzdem `0 events registered` haben. Dann wird der Effekt nicht über `actionEvents` ausgelöst, sondern direkt in einer Engine-Funktion. Klassisches Beispiel: der RMB-Cursor-Toggle (`CLICK_TO_SWITCH_TOGGLE_MOUSE`, `MOUSE_ALT_COMMAND2_BUTTON`, `MOUSE_ALT_COMMAND4_BUTTON`) — alle gebunden, alle ohne registrierte Events. Action-Event-Wrapping greift hier ins Leere.
- **Wrap-Punkt für RMB-Cursor-Toggle:** `g_inputBinding.setShowMouseCursor(self, state, ...)`. Diese Funktion ist der gemeinsame Engine-Ausgang für alle Cursor-Sichtbar-Aktionen. Wrappen reicht aus, um RMB-getriggerten Cursor während aktiver Mauslenkung zu unterdrücken:
  ```lua
  local original = g_inputBinding.setShowMouseCursor
  g_inputBinding.setShowMouseCursor = function(self, state, ...)
      if shouldSuppress() and state then return end
      return original(self, state, ...)
  end
  ```
- **Discovery-Pattern für Singleton-Funktionen:** Wenn man die richtige Funktion sucht, einmal den Singleton durchlaufen und alle Funktionsnamen ausgeben, die thematisch passen:
  ```lua
  for k, v in pairs(g_inputBinding) do
      if type(v) == "function" then
          local kl = tostring(k):lower()
          if kl:find("mouse") or kl:find("cursor") then log(k) end
      end
  end
  ```
  Hat in unserem Fall sofort `setShowMouseCursor` rausgespuckt.
- **Implement-bound axes vs. tractor `targetObject`:** Frontloader mouse axes in FS25 register as actions such as **`AXIS_FRONTLOADER_ARM`**, **`AXIS_FRONTLOADER_TOOL`**, **`AXIS_FRONTLOADER_TOOL2`** with event targets like **`attachableFrontloader`** or **`implementDynamicMountAttacher`**, not the tractor table. Iterating `actionEvents` and keeping only rows where `targetObject == controlledVehicle` **misses** the real callbacks; include rows linked via `target.rootVehicle == vehicle` or `target:getRootVehicle() == vehicle`. Parse the human-readable action name from `tostring(actionDef)` with a pattern like `"^%[([^:]+):"` — do not filter on the full string with naive `"AXIS"` substring matching or every row with `axisType=` will match.

## Mauslenk-spezifische UX-Lessons

Aus der Iteration mit dem Mauslenk-Mod, relevant für ähnliche "Eingabemodus-mit-Maus"-Features:

- **State-Reset bei Session-Start (LMB-Down):** Beim Start einer Lenk-Session immer ein "warte auf Maus-Recenter"-Flag setzen (`_awaitingRecenter = true`). In der Rate-Berechnung dann erst akkumulieren, sobald `|posX - 0.5| < ε`. Schützt vor Sprüngen, wenn die Maus durch eine vorherige Aktion (z.B. RMB-Cursor-Toggle, Menü-Bedienung) am Bildschirmrand stand. Bei normalem relative-mouse-mode clear's der Flag im selben oder nächsten Frame; bei kaputtem Mode bleibt die Lenkung sicher in Hold.
- **Single Source of Truth pro Action:** Wenn eine Action über `modDesc.xml`-Binding automatisch als Action-Event registriert ist, dann in keyEvent oder Polling NICHT zusätzlich abfragen. Die Pfade kanibalisieren sich (Doppel-Toggle). Bei Toggle-Logik fällt der Doppeltrigger auf, weil A → !A → !!A = A; bei normalen Single-Trigger-Actions wird man's nicht merken aber Code-Hygiene-mäßig Schrott.
- **Maus-Rate als Offset-vom-Zentrum, nicht als Delta:** FS25 zentriert den Cursor in relative-mouse-mode (während LMB gehalten) auf 0.5 zurück. `posX - 0.5` ist also kein "delta seit letztem Frame", sondern "wie weit will der Spieler die Lenkung gerade ziehen". Das ist ein RATE-Modell, nicht ein DELTA-Modell. Konsequenz: bei losgelassener Maus-Auslenkung läuft die Lenkung nicht zurück — sie bleibt stehen, bis der Spieler aktiv in die andere Richtung zieht. Das ist erwünscht (echte Lenkrad-Haptik) und macht den Algorithmus robust gegen Frame-Drops.
- **Frontlader + Maus:** Globales „FL montiert → immer aus“ vermeiden; stattdessen selektionsbasiert pausieren (s.o.), damit Anhänger/Zugmaschine weiter mit Mauslenkung bedienbar sind. Ctrl+M / MMB schaltet weiterhin die ganze Mod-Funktion scharf/aus.
- **Auto-Disarm bei Vehicle-Leave:** `MouseSteering:onControlledVehicleChanged(nil)` muss explizit gerufen werden, sobald `vehicle:getIsControlled()` false wird. Das Vanilla-Signal (`controlledVehicle = nil`) wird nicht automatisch propagiert. Ohne diesen Call bleibt `armed=true` hängen, und beim nächsten Einsteigen ist der State falsch.
