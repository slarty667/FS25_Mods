---This class allows easier creation of configuration options in the general settings page.
---Originally created by Farmsim Tim based on discoveries made by Shad0wlife
---Feel free to use this class in your own mods. You may change anything except for the first three lines of this file.
---version 1.3
---Changelog:
---v1.1: Fixed choice controls when using string values
---v1.2: Choice controls can now be nillable, too
---v1.3: Fix bool elements which can have invalid slider positions
---@class UIHelper
UIHelper = {}

---Creates a new section with the given title
---@param generalSettingsPage table @The general settings page of the base game
---@param i18nTitleId string @The I18N ID of the title to be displayed
---@return table|nil @The created section element
function UIHelper.createSection(generalSettingsPage, i18nTitleId)
    local sectionTitle = nil
    for _, elem in ipairs(generalSettingsPage.generalSettingsLayout.elements) do
        if elem.name == "sectionHeader" then
            sectionTitle = elem:clone(generalSettingsPage.generalSettingsLayout)
            sectionTitle:setText(g_i18n:getText(i18nTitleId))
            break
        end
    end
    if sectionTitle then
        sectionTitle.focusId = FocusManager:serveAutoFocusId()
        table.insert(generalSettingsPage.controlsList, sectionTitle)
    end
    return sectionTitle
end

---Sets the focusId properties of the element and any children to a new unique ID each
---@param element table the element
function UIHelper.updateFocusIds(element)
    if not element then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        UIHelper.updateFocusIds(child)
    end
end

local function createElement(generalSettingsPage, template, id, i18nTextId, target, callbackFunc)
    local elementBox = template:clone(generalSettingsPage.generalSettingsLayout)
    -- Remove any existing focus IDs as they would not be unique and cause trouble later on
    UIHelper.updateFocusIds(elementBox)

    elementBox.id = id .. "Box"
    -- Assign the object which shall receive change events
    local elementOption = elementBox.elements[1]
    elementOption.target = target
    elementOption:setCallback("onClickCallback", callbackFunc)
    -- WORKAROUND: The target serves two purposes:
    -- 1.) Any callback will be executed on the target object
    -- 2.) The focus manager will ignore anything which has a different target _name_ than the current UI
    -- => Since we want to allow any target for callbacks, we just copy the general settings page's name to the target
    target.name = generalSettingsPage.name
    -- Change generic values
    elementOption.id = id
    elementOption:setDisabled(false)
    -- Change the text element
    local textElement = elementBox.elements[2]
    textElement:setText(g_i18n:getText(i18nTextId .. "_short"))
    -- Change the tooltip
    local toolTip = elementOption.elements[1]
    toolTip:setText(g_i18n:getText(i18nTextId .. "_long"))

    table.insert(generalSettingsPage.controlsList, elementBox)
    return elementBox
end

---Adds a simple yes/no switch to the UI
---@param generalSettingsPage   table       @The base game object for the settings page
---@param id                    string      @The unique ID of the new element
---@param i18nTextId            string      @The key in the internationalization XML (must be two keys with a _short and _long suffix)
---@param target                table       @The object which contains the callback func
---@param callbackFunc          string      @The name of the function to call when the value changes
---@return                      table       @The created object
function UIHelper.createBoolElement(generalSettingsPage, id, i18nTextId, target, callbackFunc)
    return createElement(generalSettingsPage, generalSettingsPage.checkWoodHarvesterAutoCutBox, id, i18nTextId, target, callbackFunc)
end

---Format a numeric bound or step for tooltip text (decimals match the UI slider labels).
---@param value number
---@param step number
---@return string
function UIHelper.formatTooltipNumber(value, step)
    local digits = 0
    local tmpStep = step
    while tmpStep < 1 do
        digits = digits + 1
        tmpStep = tmpStep * 10
    end
    if digits == 0 then
        return tostring(math.floor(value + 0.5))
    end
    local formatTemplate = "%." .. digits .. "f"
    return formatTemplate:format(value)
end

---Creates an element which allows choosing one out of several text values
function UIHelper.createChoiceElement(generalSettingsPage, id, i18nTextId, i18nValueMap, target, callbackFunc, nillable)
    local choiceElementBox = createElement(generalSettingsPage, generalSettingsPage.multiVolumeVoiceBox, id, i18nTextId, target, callbackFunc)

    local choiceElement = choiceElementBox.elements[1]
    local texts = {}

    if nillable then
        table.insert(texts, "-")
    end
    for _, valueEntry in pairs(i18nValueMap) do
        local value
        if type(valueEntry) == "number" then
            value = tostring(valueEntry)
        elseif type(valueEntry) == "string" then
            value = g_i18n:getText(valueEntry)
            choiceElementBox.hasStrings = true
        else
            -- legacy syntax
            value = g_i18n:getText(valueEntry.i18nTextId)
            choiceElementBox.hasStrings = true
        end
        table.insert(texts, value)
    end
    choiceElement:setTexts(texts)

    return choiceElementBox
end

---Creates an element which allows choosing one out of several numeric values
function UIHelper.createRangeElement(generalSettingsPage, id, i18nTextId, minValue, maxValue, step, unit, target, callbackFunc, nillable)
    local rangeElementBox = createElement(generalSettingsPage, generalSettingsPage.multiVolumeVoiceBox, id, i18nTextId, target, callbackFunc)

    local rangeElement = rangeElementBox.elements[1]
    local texts = {}

    if nillable then
        table.insert(texts, "-")
    end

    local digits = 0
    local tmpStep = step
    while tmpStep < 1 do
        digits = digits + 1
        tmpStep = tmpStep * 10
    end
    local formatTemplate = (".%df"):format(digits)
    for i = minValue, maxValue, step do
        local text = ("%" .. formatTemplate):format(i)
        if unit then
            text = ("%s %s"):format(text, unit)
        end
        table.insert(texts, text)
    end
    rangeElement:setTexts(texts)

    local toolTip = rangeElement.elements[1]
    local baseHint = g_i18n:getText(i18nTextId .. "_long")
    local minStr = UIHelper.formatTooltipNumber(minValue, step)
    local maxStr = UIHelper.formatTooltipNumber(maxValue, step)
    local stepStr = UIHelper.formatTooltipNumber(step, step)
    local rangeHint = "\n\n" .. string.format(g_i18n:getText("ms_tooltip_range_bounds"), minStr, maxStr, stepStr)
    toolTip:setText(baseHint .. rangeHint)

    return rangeElementBox
end

---Dynamically creates controls based on the controlProperties configuration table.
---For bool values, supply just the name, for ranges, additionally supply min, max and step, and for choices, supply a values table in addition to the name
---For each control name, l10n keys <prefix><name>_short and <prefix><name>_long must exist.
---For each control, a on_<name>_changed callback will be called on change.
function UIHelper.createControlsDynamically(settingsPage, sectionTitle, owningTable, controlProperties, prefix)
    owningTable.sectionTitle = UIHelper.createSection(settingsPage, sectionTitle)
    owningTable.controls[1] = owningTable.sectionTitle

    for _, controlProps in ipairs(controlProperties) do
        local uiControl
        local id = prefix .. controlProps.name
        local callback = "on_" .. controlProps.name .. "_changed"
        if controlProps.min ~= nil then
            -- number range control
            uiControl = UIHelper.createRangeElement(
                settingsPage, id, id,
                controlProps.min, controlProps.max, controlProps.step, controlProps.unit,
                owningTable, callback, controlProps.nillable)

            uiControl.min = controlProps.min
            uiControl.max = controlProps.max
            uiControl.step = controlProps.step
            uiControl.nillable = controlProps.nillable

        elseif controlProps.values ~= nil then
            -- enum control
            uiControl = UIHelper.createChoiceElement(settingsPage, id, id, controlProps.values, owningTable, callback, controlProps.nillable)
            uiControl.values = controlProps.values
            uiControl.nillable = controlProps.nillable
        else
            -- bool switch
            uiControl = UIHelper.createBoolElement(settingsPage, id, id, owningTable, callback)
        end

        uiControl.autoBind = controlProps.autoBind
        uiControl.name = controlProps.name
        uiControl.subTable = controlProps.subTable
        uiControl.propName = controlProps.propName
        table.insert(owningTable.controls, uiControl)
        owningTable[controlProps.name] = uiControl

        UIHelper.registerFocusControls(owningTable.controls)
        settingsPage.generalSettingsLayout:invalidateLayout()
    end
end

---Hooks into the focus manager at just the right point in time to register any relevant controls.
function UIHelper.registerFocusControls(controls)
    FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
        for _, control in ipairs(controls) do
            if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    Logging.warning("Failed loading focus element for %s. Keyboard/controller menu navigation might be bugged.", control.id or control.name)
                end
            end
        end
        local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
        settingsPage.generalSettingsLayout:invalidateLayout()
    end)
end

---Makes sure UI controls are being populated with data from targetTable when the settings frame gets opened,
---and updates the properties in targetTable when the user changes values.
function UIHelper.setupAutoBindControls(owningTable, targetTable, updateFunc)
    owningTable.populateAutoBindControls = function()
        for _, control in ipairs(owningTable.controls) do
            if control.autoBind then
                local value = UIHelper.getAutoBoundValueFromTable(control, targetTable)
                UIHelper.setControlValue(control, value)
            end
        end
    end
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, owningTable.populateAutoBindControls)
    for _, control in ipairs(owningTable.controls) do
        if control.autoBind then
            local callbackName = "on_autoBind_" .. control.name .. "_changed"
            owningTable[callbackName] = function(self, newState)
                local newValue = UIHelper.getControlValue(control, newState)
                UIHelper.setAutoBoundValueInTable(control, newValue, targetTable)
                if updateFunc then
                    updateFunc(owningTable, control)
                end
            end
            control.elements[1]:setCallback("onClickCallback", callbackName)
        end
    end
end

function UIHelper.getAutoBoundValueFromTable(control, targetTable)
    if control.subTable == nil then
        return targetTable[control.propName or control.name]
    else
        return targetTable[control.subTable][control.propName or control.name]
    end
end

function UIHelper.setAutoBoundValueInTable(control, value, targetTable)
    if control.subTable == nil then
        targetTable[control.propName or control.name or "ERROR"] = value
    else
        targetTable[control.subTable][control.propName or control.name] = value
    end
end

function UIHelper.setRangeValue(control, value)
    local valueIndex
    if control.nillable and value == nil then
        valueIndex = 1
    else
        valueIndex = math.floor(((value - control.min) / control.step + 1) + 0.5)
        if control.nillable then
            valueIndex = valueIndex + 1
        end
    end
    control.elements[1]:setState(valueIndex)
end

function UIHelper.getRangeValue(control, controlState)
    if control.nillable and controlState == 1 then
        return nil
    else
        local offset = 1
        if control.nillable then
            offset = 2
        end
        return control.min + control.step * (controlState - offset)
    end
end

function UIHelper.setChoiceValue(control, value)
    if control.hasStrings then
        control.elements[1]:setState(value)
    else
        for index, val in control.values do
            if val == value then
                control.elements[1]:setState(index)
            end
        end
    end
end

function UIHelper.getChoiceValue(control, controlState)
    if control.hasStrings then
        return controlState
    else
        return control.values[controlState]
    end
end

function UIHelper.setBoolValue(control, value)
    control.elements[1]:setState(value and BinaryOptionElement.STATE_RIGHT or BinaryOptionElement.STATE_LEFT)
end

function UIHelper.getBoolValue(controlState)
    return controlState == 2
end

function UIHelper.setControlValue(control, value)
    if control.min ~= nil then
        UIHelper.setRangeValue(control, value)
    elseif control.values ~= nil then
        UIHelper.setChoiceValue(control, value)
    else
        UIHelper.setBoolValue(control, value)
    end
end

function UIHelper.getControlValue(control, controlState)
    if control.min ~= nil then
        return UIHelper.getRangeValue(control, controlState)
    elseif control.values ~= nil then
        return UIHelper.getChoiceValue(control, controlState)
    else
        return UIHelper.getBoolValue(controlState)
    end
end

-- Bugfix the "slider" of Off/On elements which can sometimes go out of bounds
BinaryOptionElement.update = Utils.appendedFunction(BinaryOptionElement.update, function(element, _)
    if element.sliderState < 0 then
        element.sliderState = 0
        element.sliderElement:setPosition(0)
    end
end)
