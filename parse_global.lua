local datapath = './.fg/'

-- Dependencies
local lfs = require('lfs') -- luafilesystem
local parseXmlFile = require('xmlparser').parseFile

-- Datatypes
local packages = {
	[1] = {
		['name'] = 'rulesets',
		['path'] = datapath .. 'rulesets/',
		['baseFile'] = 'base.xml',
		['definitions'] = {},
		['packageList'] = {},
	},
	[2] = {
		['name'] = 'extensions',
		['path'] = datapath .. 'extensions/',
		['baseFile'] = 'extension.xml',
		['definitions'] = {},
		['packageList'] = {},
	},
}

--
-- General Functions (called from multiple places)
--

-- Calls luac and find included SETGLOBAL commands
-- Adds them to supplied table 'globals'
local function findGlobals(globals, filePath)

	local function executeCapture(command)
		local file = assert(io.popen(command, 'r'))
		local str = assert(file:read('*a'))
		str = string.gsub(str, '^%s+', '')
		str = string.gsub(str, '%s+$', '')

		file:close()
		return str
	end

	if lfs.touch(filePath) then
		executeCapture('perl -e \'s/\\xef\\xbb\\xbf//;\' -pi ' .. filePath)
		local content = executeCapture(string.format('%s -l -p ' .. filePath, 'luac'))

		for line in content:gmatch('[^\r\n]+') do
			if line:match('SETGLOBAL%s+') and not line:match('%s+;%s+(_)%s*') then
				local globalName = line:match('\t; (.+)%s*')
				globals[globalName] = true
			end
		end

		return true
	end
end

-- Checks next level of XML data table for  elements matching a supplied tag name
-- If found, returns the XML data table of that child element
local function findXmlElement(root, searchStrings)
	if root and root.children then
		for _, xmlElement in ipairs(root.children) do
			for _, searchString in ipairs(searchStrings) do if xmlElement.tag == searchString then return xmlElement end end
		end
	end
end

local function simplifyObjectName(string)
	if string then string:gsub('%-', '_') end
	return string
end

-- Calls findGlobals for lua functions in XML-formatted string
-- Creates temp file, writes string to it, calls findGlobals, deletes temp file
local function getFnsFromLuaInXml(fns, data)

	-- Converts XML escaped strings into the base characters.
	-- &gt; to >, for example. This allows the lua parser to handle it correctly.
	local function convertXmlEscapes(string)
		string = string:gsub('&amp;', '&')
		string = string:gsub('&quot;', '"')
		string = string:gsub('&apos;', '\'')
		string = string:gsub('&lt;', '<')
		string = string:gsub('&gt;', '>')
		return string
	end

	local tempFilePath = datapath .. 'xmlscript.tmp'
	local tempFile = assert(io.open(tempFilePath, 'w'), 'Error opening file ' .. tempFilePath)

	local script = convertXmlEscapes(data)

	tempFile:write(script)
	tempFile:close()

	findGlobals(fns, datapath .. 'xmlscript.tmp')

	os.remove(tempFilePath)
end

-- Searches other rulesets for provided lua file name.
-- If found, adds to provided table. Package path is prepended to file path.
local function findAltScriptLocation(templateFunctions, packagePath, filePath)
	for _, packageName in ipairs(packages[1].packageList) do
		if packageName ~= packagePath[4] then
			local altPackagePath = packagePath
			altPackagePath[4] = packageName
			findGlobals(templateFunctions, table.concat(altPackagePath) .. '/' .. filePath)
		end
	end
end

--
-- Main Functions (called from Main Chunk)
--

-- 
local function writeDefinitionsToFile(defintitions, package)

	-- 
	local function gatherChildFunctions(output)

		-- 
		local function writeSubdefintions(fns)
			local subdefinition = ''

			for fn, _ in pairs(fns) do
				subdefinition = subdefinition .. '\t\t' .. fn ..
								                ' = {\n\t\t\t\tread_only = false,\n\t\t\t\tother_fields = false,\n\t\t\t},\n\t'
			end

			return subdefinition
		end

		for parent, fns in pairs(defintitions[package]) do
			local global = (parent .. ' = {\n\t\tread_only = false,\n\t\tfields = {\n\t' .. writeSubdefintions(fns) ..
							               '\t},\n\t},')
			table.insert(output, global)
		end
		table.sort(output)
	end

	local output = {}
	gatherChildFunctions(output)

	local dir = datapath .. 'globals/'
	lfs.mkdir(dir)
	local filePath = dir .. package .. '.luacheckrc_std'
	local destFile = assert(io.open(filePath, 'w'), 'Error opening file ' .. filePath)
	destFile:write('globals = {\n')
	for _, var in ipairs(output) do destFile:write('\t' .. var .. '\n') end

	destFile:write('\n},\n')
	destFile:close()
end

-- Search through a supplied fantasygrounds xml file to find other defined xml files.
local function findNamedLuaScripts(definitions, baseXmlFile, packagePath)

	local function recursiveScriptSearch(element)

		local function callFindGlobals()
			local fns = {}
			findGlobals(fns, table.concat(packagePath) .. '/' .. element.attrs.file)
			definitions[element.attrs.name] = fns
			return true
		end

		if element.tag == 'script' and element.attrs.file then
			callFindGlobals()
		elseif element.children then
			for _, child in ipairs(element.children) do recursiveScriptSearch(child) end
		end
	end

	local root = findXmlElement(parseXmlFile(baseXmlFile), { 'root' })
	if root then for _, element in ipairs(root.children) do recursiveScriptSearch(element) end end
end

-- Searches a provided table of XML files for script definitions.
-- If element is windowclass, call getWindowclassScript.
-- If element is not a template, call xmlScriptSearch
local function findInterfaceScripts(packageDefinitions, templates, xmlFiles, packagePath)

	-- Checks the first level of the provided xml data table for an element with the
	-- tag 'script'. If found, it calls getScriptFromXml to map its globals and then calls
	-- insertTableKeys to add any inherited template functions.
	local function xmlScriptSearch(sheetdata)

		-- Copies keys from sourceTable to destinationTable with boolean value true
		local function insertTableKeys(sourceTable, destinationTable)
			for fn, _ in pairs(sourceTable) do destinationTable[fn] = true end
		end

		-- When supplied with a lua-xmlparser table for the <script> element,
		-- this function adds any functions from it into a supplied table.
		local function getScriptFromXml(parent, script)
			if parent.attrs.name then
				local fns = {}
				if script and script.attrs.file then
					if not findGlobals(fns, table.concat(packagePath) .. '/' .. script.attrs.file) then
						findAltScriptLocation(fns, packagePath, script.attrs.file)
					end
				elseif script and script.children[1].text then
					getFnsFromLuaInXml(fns, script.children[1].text)
				end

				packageDefinitions[simplifyObjectName(parent.attrs.name)] = fns
			end
		end

		for _, element in ipairs(sheetdata.children) do
			local script = findXmlElement(element, { 'script' })
			getScriptFromXml(element, script)
			if templates[simplifyObjectName(element.tag)] and templates[simplifyObjectName(element.tag)].functions and
							packageDefinitions[simplifyObjectName(element.attrs.name)] then
				insertTableKeys(
								templates[simplifyObjectName(element.tag)].functions, packageDefinitions[simplifyObjectName(element.attrs.name)]
				)
			end
		end
	end

	-- Searches provided element for lua script definition and adds to provided table
	-- If file search within package is unsuccessful, it calls findAltScriptLocation to search all rulesets
	-- Finally, it adds the discovered functions to PackageDefintions under the key of the UI object name.
	local function getWindowclassScript(element)
		local script = findXmlElement(element, { 'script' })
		if script then
			local fns = {}
			if script.attrs.file then
				if not findGlobals(fns, table.concat(packagePath) .. '/' .. script.attrs.file) then
					findAltScriptLocation(fns, packagePath, script.attrs.file)
				end
			elseif script.children[1] and script.children[1].text then
				getFnsFromLuaInXml(fns, script.children[1].text)
			end
			packageDefinitions[simplifyObjectName(element.attrs.name)] = fns
		end
	end

	for _, xmlPath in pairs(xmlFiles) do -- iterate through provided files
		local root = findXmlElement(parseXmlFile(xmlPath), { 'root' }) -- use first root element
		for _, element in ipairs(root.children) do
			if element.tag == 'windowclass' then -- iterate through each windowclass
				getWindowclassScript(element)
				local sheetdata = findXmlElement(element, { 'sheetdata' }) -- use first sheetdata element
				if sheetdata then xmlScriptSearch(sheetdata) end
			end
		end
	end
end

local function matchRelationshipScripts(templates)
	for _, template in pairs(templates) do
		local inheritedTemplates = template.inherit
		if inheritedTemplates then
			for inherit, _ in pairs(inheritedTemplates) do
				if inherit and templates[simplifyObjectName(inherit)] and templates[simplifyObjectName(inherit)].functions and
								template.functions then
					for functionName, _ in pairs(templates[simplifyObjectName(inherit)].functions) do
						template.functions[functionName] = true
					end
				end
			end
		end
	end
end

-- Finds template definitions in supplied table of XML files.
-- If found, calls findTemplateScript to extract a list of globals.
local function findTemplateRelationships(templates, packagePath, xmlFiles)

	-- When supplied with a lua-xmlparser table for the <script> element of a template,
	-- this function adds any functions from it into a supplied table.
	local function findTemplateScript(parent, element)
		local script = findXmlElement(parent, { 'script' })
		if script then
			local templateFunctions = {}
			if script.attrs.file then
				if not findGlobals(templateFunctions, table.concat(packagePath) .. '/' .. script.attrs.file) then
					findAltScriptLocation(templateFunctions, packagePath, script.attrs.file)
				end
			elseif script.children[1].text then
				getFnsFromLuaInXml(templateFunctions, script.children[1].text)
			end
			templates[simplifyObjectName(element.attrs.name)] = {
				['inherit'] = { [simplifyObjectName(parent.tag)] = true },
				['functions'] = templateFunctions,
			}
		end
	end

	for _, xmlPath in pairs(xmlFiles) do
		local root = findXmlElement(parseXmlFile(xmlPath), { 'root' })
		for _, element in ipairs(root.children) do
			if element.tag == 'template' then
				for _, template in ipairs(element.children) do findTemplateScript(template, element) end
			end
		end
	end
end

-- Search through a supplied fantasygrounds xml file to find other defined xml files.
local function findXmls(xmlFiles, xmlDefinitionsPath, packagePath)

	local function addXmlToTable(element)
		if element.tag == 'includefile' then
			local fileName = element.attrs.source
			fileName = fileName:match('.+/(.-).xml') or fileName:match('(.-).xml')
			xmlFiles[fileName] = table.concat(packagePath) .. '/' .. element.attrs.source
			return true
		elseif element.children then
			for _, child in ipairs(element.children) do addXmlToTable(child) end
		end
	end

	local root = findXmlElement(parseXmlFile(xmlDefinitionsPath), { 'root' }) -- use first root element
	if root then
		for _, element in ipairs(root.children) do
			if not addXmlToTable(element) then for _, child in ipairs(element.children) do addXmlToTable(child) end end
		end
	end
end

-- Determine best package name
-- Returns as a lowercase string
local function getPackageName(baseXmlFile, packageName)

	-- Trims package name to prevent issues with luacheckrc
	local function simplifyText(text)
		text = text:gsub('.+:', '') -- remove prefix
		text = text:gsub('%(.+%)', '') -- remove parenthetical
		text = text:gsub('%W', '') -- remove non alphanumeric
		return text
	end

	-- Reads supplied XML file to find name and author definitions.
	-- Returns a simplified string to identify the extension
	local function getSimpleName()

		local altName = { '' }
		local xmlProperties = findXmlElement(findXmlElement(parseXmlFile(baseXmlFile), { 'root' }), { 'properties' })
		if xmlProperties then
			for _, element in ipairs(xmlProperties.children) do
				if element.tag == 'author' then
					table.insert(altName, 2, simplifyText(element.children[1].text))
				elseif element.tag == 'name' then
					table.insert(altName, 1, simplifyText(element.children[1].text))
				end
			end
		end

		return table.concat(altName)
	end
	local shortPackageName = getSimpleName()

	if shortPackageName == '' then shortPackageName = simplifyText(packageName) end

	-- prepend 'def' if 1st character isn't a-z
	if string.sub(shortPackageName, 1, 1):match('%A') then shortPackageName = 'def' .. shortPackageName end

	return shortPackageName:lower()
end

-- Searches for file by name in supplied directory
-- Returns string in format of 'original_path/file_result'
local function findBaseXml(path, searchName)
	local concatPath = table.concat(path)
	for file in lfs.dir(concatPath) do
		local filePath = concatPath .. '/' .. file
		local fileType = lfs.attributes(filePath, 'mode')
		if fileType == 'file' and string.find(file, searchName) then return filePath end
	end
end

-- Searches for directories in supplied path
-- Adds them to supplied table 'list' and sorts the table
local function findAllPackages(list, path)
	lfs.mkdir(path) -- if not found, create path to avoid errors

	for file in lfs.dir(path) do
		if lfs.attributes(path .. '/' .. file, 'mode') == 'directory' then
			if file ~= '.' and file ~= '..' then table.insert(list, file) end
		end
	end

	table.sort(list)
end

local function getAPIfunctions(templates)

	local function getApiDefinitions()
		return {
			['windowcontrol'] = {
				['functions'] = {
					['bringToFront'] = true,
					['destroy'] = true,
					['getName'] = true,
					['getPosition'] = true,
					['getScrollState'] = true,
					['getSize'] = true,
					['getTabTarget'] = true,
					['isEnabled'] = true,
					['isReadOnly'] = true,
					['isVisible'] = true,
					['onClickDown'] = true,
					['onClickRelease'] = true,
					['onClose'] = true,
					['onDoubleClick'] = true,
					['onDrag'] = true,
					['onDragEnd'] = true,
					['onDragStart'] = true,
					['onDrop'] = true,
					['onFirstLayout'] = true,
					['onHover'] = true,
					['onHoverUpdate'] = true,
					['onInit'] = true,
					['onMenuSelection'] = true,
					['onScroll'] = true,
					['onVisibilityChanged'] = true,
					['onWheel'] = true,
					['onZoom'] = true,
					['registerMenuItem'] = true,
					['resetAnchor'] = true,
					['resetMenuItems'] = true,
					['sendToBack'] = true,
					['setAnchor'] = true,
					['setAnchoredHeight'] = true,
					['setAnchoredWidth'] = true,
					['setBackColor'] = true,
					['setEnabled'] = true,
					['setFrame'] = true,
					['setHoverCursor'] = true,
					['setReadOnly'] = true,
					['setScrollPosition'] = true,
					['setStateFrame'] = true,
					['setStaticBounds'] = true,
					['setTabTarget'] = true,
					['setTooltipText'] = true,
					['setVisible'] = true,
				},
				['inherit'] = {},
			},
			['widget'] = {
				['functions'] = {
					['bringToFront'] = true,
					['destroy'] = true,
					['getSize'] = true,
					['sendToBack'] = true,
					['setEnabled'] = true,
					['setFrame'] = true,
					['setPosition'] = true,
					['setRadialPosition'] = true,
					['setVisible'] = true,
				},
				['inherit'] = {},
			},
			['dragdata'] = {
				['functions'] = {
					['addDie'] = true,
					['addShortcut'] = true,
					['createBaseData'] = true,
					['disableHotkeying'] = true,
					['getCustomData'] = true,
					['getDatabaseNode'] = true,
					['getDescription'] = true,
					['getDieList'] = true,
					['getMetaData'] = true,
					['getMetaDataList'] = true,
					['getNumberData'] = true,
					['getSecret'] = true,
					['getShortcutData'] = true,
					['getShortcutList'] = true,
					['getSlot'] = true,
					['getSlotCount'] = true,
					['getSlotType'] = true,
					['getStringData'] = true,
					['getTokenData'] = true,
					['getType'] = true,
					['isType'] = true,
					['nextSlot'] = true,
					['reset'] = true,
					['resetType'] = true,
					['revealDice'] = true,
					['setCustomData'] = true,
					['setData'] = true,
					['setDatabaseNode'] = true,
					['setDescription'] = true,
					['setDieList'] = true,
					['setIcon'] = true,
					['setMetaData'] = true,
					['setNumberData'] = true,
					['setSecret'] = true,
					['setShortcutData'] = true,
					['setSlot'] = true,
					['setSlotType'] = true,
					['setStringData'] = true,
					['setTokenData'] = true,
					['setType'] = true,
				},
				['inherit'] = {},
			},
			['databasenode'] = {
				['functions'] = {
					['addChildCategory'] = true,
					['addHolder'] = true,
					['createChild'] = true,
					['delete'] = true,
					['getCategory'] = true,
					['getChild'] = true,
					['getChildCategories'] = true,
					['getChildCount'] = true,
					['getChildren'] = true,
					['getDefaultChildCategory'] = true,
					['getHolders'] = true,
					['getModule'] = true,
					['getName'] = true,
					['getNodeName'] = true,
					['getOwner'] = true,
					['getParent'] = true,
					['getPath'] = true,
					['getRulesetVersion'] = true,
					['getText'] = true,
					['getType'] = true,
					['getValue'] = true,
					['getVersion'] = true,
					['isIntact'] = true,
					['isOwner'] = true,
					['isPublic'] = true,
					['isReadOnly'] = true,
					['isStatic'] = true,
					['onChildAdded'] = true,
					['onChildDeleted'] = true,
					['onChildUpdate'] = true,
					['onDelete'] = true,
					['onIntegrityChange'] = true,
					['onObserverUpdate'] = true,
					['onUpdate'] = true,
					['removeAllHolders'] = true,
					['removeChildCategory'] = true,
					['removeHolder'] = true,
					['revert'] = true,
					['setCategory'] = true,
					['setDefaultChildCategory'] = true,
					['setPublic'] = true,
					['setStatic'] = true,
					['setValue'] = true,
					['updateChildCategory'] = true,
					['updateVersion'] = true,
				},
				['inherit'] = {},
			},
			['windowinstance'] = {
				['functions'] = {
					['bringToFront'] = true,
					['close'] = true,
					['createControl'] = true,
					['getClass'] = true,
					['getControls'] = true,
					['getDatabaseNode'] = true,
					['getFrame'] = true,
					['getLockState'] = true,
					['getPosition'] = true,
					['getSize'] = true,
					['getTooltipText'] = true,
					['getViewers'] = true,
					['isMinimized'] = true,
					['isShared'] = true,
					['notifyUpdate'] = true,
					['onClose'] = true,
					['onDrop'] = true,
					['onFirstLayout'] = true,
					['onHover'] = true,
					['onHoverUpdate'] = true,
					['onInit'] = true,
					['onLockStateChanged'] = true,
					['onMenuSelection'] = true,
					['onMove'] = true,
					['onSizeChanged'] = true,
					['onSubwindowInstantiated'] = true,
					['onViewersChanged'] = true,
					['registerMenuItem'] = true,
					['resetMenuItems'] = true,
					['setBackColor'] = true,
					['setEnabled'] = true,
					['setFrame'] = true,
					['setLockState'] = true,
					['setPosition'] = true,
					['setSize'] = true,
					['setTooltipText'] = true,
					['share'] = true,
				},
				['inherit'] = {},
			},
			['widgetcontainer'] = { ['functions'] = { ['addBitmapWidget'] = true, ['addTextWidget'] = true }, ['inherit'] = {} },
			['tokeninstance'] = {
				['functions'] = {
					['addUnderlay'] = true,
					['clearTargets'] = true,
					['delete'] = true,
					['getContainerNode'] = true,
					['getContainerScale'] = true,
					['getId'] = true,
					['getImageSize'] = true,
					['getName'] = true,
					['getOrientation'] = true,
					['getPosition'] = true,
					['getPrototype'] = true,
					['getScale'] = true,
					['getTargetingIdentities'] = true,
					['getTargets'] = true,
					['isActivable'] = true,
					['isActive'] = true,
					['isModifiable'] = true,
					['isTargetable'] = true,
					['isTargeted'] = true,
					['isTargetedBy'] = true,
					['isTargetedByIdentity'] = true,
					['isVisible'] = true,
					['onActivation'] = true,
					['onClickDown'] = true,
					['onClickRelease'] = true,
					['onContainerChanged'] = true,
					['onContainerChanging'] = true,
					['onDelete'] = true,
					['onDoubleClick'] = true,
					['onDrag'] = true,
					['onDragEnd'] = true,
					['onDragStart'] = true,
					['onDrop'] = true,
					['onHover'] = true,
					['onHoverUpdate'] = true,
					['onMenuSelection'] = true,
					['onMove'] = true,
					['onScaleChanged'] = true,
					['onTargetUpdate'] = true,
					['onTargetedUpdate'] = true,
					['onWheel'] = true,
					['registerMenuItem'] = true,
					['removeAllUnderlays'] = true,
					['resetMenuItems'] = true,
					['setActivable'] = true,
					['setActive'] = true,
					['setContainerScale'] = true,
					['setModifiable'] = true,
					['setName'] = true,
					['setOrientation'] = true,
					['setOrientationMode'] = true,
					['setPosition'] = true,
					['setScale'] = true,
					['setTarget'] = true,
					['setTargetable'] = true,
					['setVisible'] = true,
				},
				['inherit'] = {},
			},
			['buttoncontrol'] = {
				['functions'] = {
					['getValue'] = true,
					['onButtonPress'] = true,
					['onValueChanged'] = true,
					['setColor'] = true,
					['setIcons'] = true,
					['setStateColor'] = true,
					['setStateIcons'] = true,
					['setStateText'] = true,
					['setStateTooltipText'] = true,
					['setText'] = true,
					['setTooltipText'] = true,
					['setValue'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['tokencontrol'] = {
				['functions'] = {
					['getPrototype'] = true,
					['onValueChanged'] = true,
					['populateFromImageNode'] = true,
					['setPrototype'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['tokenbag'] = {
				['functions'] = { ['getZoom'] = true, ['setZoom'] = true },
				['inherit'] = { ['windowcontrol'] = true },
			},
			['subwindow'] = {
				['functions'] = { ['getValue'] = true, ['onInstanceCreated'] = true, ['setValue'] = true },
				['inherit'] = { ['windowcontrol'] = true },
			},
			['stringcontrol'] = {
				['functions'] = { ['getEmptyText'] = true, ['onValueChanged'] = true, ['setEmptyText'] = true },
				['inherit'] = { ['windowcontrol'] = true, ['textbasecontrol'] = true },
			},
			['scrollbarcontrol'] = { ['functions'] = { ['setTarget'] = true }, ['inherit'] = { ['windowcontrol'] = true } },
			['portraitselectioncontrol'] = {
				['functions'] = { ['activate'] = true, ['getFile'] = true, ['setFile'] = true },
				['inherit'] = { ['windowcontrol'] = true },
			},
			['genericcontrol'] = {
				['functions'] = { ['hasIcon'] = true, ['setColor'] = true, ['setIcon'] = true },
				['inherit'] = { ['windowcontrol'] = true },
			},
			['databasecontrol'] = { ['functions'] = { ['getDatabaseNode'] = true }, ['inherit'] = {} },
			['diecontrol'] = {
				['functions'] = {
					['addDie'] = true,
					['getDice'] = true,
					['isEmpty'] = true,
					['onValueChanged'] = true,
					['reset'] = true,
					['setDice'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['chatwindow'] = {
				['functions'] = {
					['addMessage'] = true,
					['clear'] = true,
					['deliverMessage'] = true,
					['onDiceLanded'] = true,
					['onDiceTotal'] = true,
					['onReceiveMessage'] = true,
					['throwDice'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['formattedtextcontrol'] = {
				['functions'] = {
					['isEmpty'] = true,
					['onGainFocus'] = true,
					['onLoseFocus'] = true,
					['onValueChanged'] = true,
					['setFocus'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['imagecontrol'] = {
				['functions'] = {
					['addToken'] = true,
					['clearSelectedTokens'] = true,
					['deleteDrawing'] = true,
					['enableGridPlacement'] = true,
					['getCursorMode'] = true,
					['getDistanceBetween'] = true,
					['getDrawingTool'] = true,
					['getGridHexElementDimensions'] = true,
					['getGridOffset'] = true,
					['getGridSize'] = true,
					['getGridSnap'] = true,
					['getGridType'] = true,
					['getImageSize'] = true,
					['getMaskTool'] = true,
					['getSelectedTokens'] = true,
					['getTokenLockState'] = true,
					['getTokenOrientationCount'] = true,
					['getTokenScale'] = true,
					['getTokens'] = true,
					['getTokensWithinDistance'] = true,
					['getViewpoint'] = true,
					['hasDrawing'] = true,
					['hasGrid'] = true,
					['hasMask'] = true,
					['hasTokens'] = true,
					['isTokenSelected'] = true,
					['onCursorModeChanged'] = true,
					['onDrawStateChanged'] = true,
					['onDrawingSizeChanged'] = true,
					['onGridStateChanged'] = true,
					['onMaskingStateChanged'] = true,
					['onMeasurePointer'] = true,
					['onMeasureVector'] = true,
					['onPointerSnap'] = true,
					['onTargetSelect'] = true,
					['onTokenAdded'] = true,
					['onTokenSnap'] = true,
					['preload'] = true,
					['resetPointers'] = true,
					['selectToken'] = true,
					['setCursorMode'] = true,
					['setDrawingSize'] = true,
					['setDrawingTool'] = true,
					['setGridOffset'] = true,
					['setGridSize'] = true,
					['setGridSnap'] = true,
					['setGridToolType'] = true,
					['setGridType'] = true,
					['setMaskEnabled'] = true,
					['setMaskTool'] = true,
					['setTokenLockState'] = true,
					['setTokenOrientationCount'] = true,
					['setTokenOrientationMode'] = true,
					['setTokenScale'] = true,
					['setViewpoint'] = true,
					['setViewpointCenter'] = true,
					['snapToGrid'] = true,
				},
				['inherit'] = { ['databasecontrol'] = true, ['windowcontrol'] = true },
			},
			['chatentry'] = {
				['functions'] = { ['onDeliverMessage'] = true, ['onSlashCommand'] = true },
				['inherit'] = { ['windowcontrol'] = true, ['textbasecontrol'] = true },
			},
			['buttonfield'] = { ['functions'] = {}, ['inherit'] = { ['databasecontrol'] = true, ['buttoncontrol'] = true } },
			['windowreferencefield'] = {
				['functions'] = {},
				['inherit'] = { ['databasecontrol'] = true, ['windowreferencecontrol'] = true },
			},
			['tokenfield'] = { ['functions'] = {}, ['inherit'] = { ['databasecontrol'] = true, ['tokencontrol'] = true } },
			['stringfield'] = { ['functions'] = {}, ['inherit'] = { ['databasecontrol'] = true, ['stringfield'] = true } },
			['numberfield'] = { ['functions'] = {}, ['inherit'] = { ['databasecontrol'] = true, ['numbercontrol'] = true } },
			['diefield'] = { ['functions'] = {}, ['inherit'] = { ['databasecontrol'] = true, ['diecontrol'] = true } },
			['formattedtextfield'] = {
				['functions'] = {},
				['inherit'] = { ['databasecontrol'] = true, ['formattedtextcontrol'] = true },
			},
			['scrollercontrol'] = { ['functions'] = {}, ['inherit'] = { ['windowcontrol'] = true } },
			['textwidget'] = {
				['functions'] = {
					['getText'] = true,
					['setColor'] = true,
					['setFont'] = true,
					['setMaxWidth'] = true,
					['setText'] = true,
				},
				['inherit'] = { ['widget'] = true },
			},
			['numbercontrol'] = {
				['functions'] = {
					['getFont'] = true,
					['getMaxValue'] = true,
					['getMinValue'] = true,
					['getValue'] = true,
					['hasFocus'] = true,
					['onChar'] = true,
					['onEnter'] = true,
					['onGainFocus'] = true,
					['onLoseFocus'] = true,
					['onTab'] = true,
					['onValueChanged'] = true,
					['setColor'] = true,
					['setDescriptionField'] = true,
					['setDescriptionText'] = true,
					['setFocus'] = true,
					['setFont'] = true,
					['setMaxValue'] = true,
					['setMinValue'] = true,
					['setValue'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['windowreferencecontrol'] = {
				['functions'] = {
					['activate'] = true,
					['getTargetDatabaseNode'] = true,
					['getValue'] = true,
					['isEmpty'] = true,
					['onValueChanged'] = true,
					['setIcons'] = true,
					['setValue'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
			['windowlist'] = {
				['functions'] = {
					['applyFilter'] = true,
					['applySort'] = true,
					['closeAll'] = true,
					['createWindow'] = true,
					['createWindowWithClass'] = true,
					['getColumnWidth'] = true,
					['getNextWindow'] = true,
					['getPrevWindow'] = true,
					['getWindowAt'] = true,
					['getWindowCount'] = true,
					['getWindows'] = true,
					['hasFocus'] = true,
					['onFilter'] = true,
					['onGainFocus'] = true,
					['onListChanged'] = true,
					['onListRearranged'] = true,
					['onLoseFocus'] = true,
					['onSortCompare'] = true,
					['scrollToWindow'] = true,
					['setColumnWidth'] = true,
					['setDatabaseNode'] = true,
					['setFocus'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true, ['databasecontrol'] = true },
			},
			['bitmapwidget'] = {
				['functions'] = { ['getBitmapName'] = true, ['setBitmap'] = true, ['setColor'] = true, ['setSize'] = true },
				['inherit'] = { ['widget'] = true },
			},
			['textbasecontrol'] = {
				['functions'] = {
					['getCursorPosition'] = true,
					['getFont'] = true,
					['getSelectionPosition'] = true,
					['getValue'] = true,
					['hasFocus'] = true,
					['isEmpty'] = true,
					['onChar'] = true,
					['onDeleteDown'] = true,
					['onDeleteUp'] = true,
					['onEnter'] = true,
					['onGainFocus'] = true,
					['onLoseFocus'] = true,
					['onNavigateDown'] = true,
					['onNavigateLeft'] = true,
					['onNavigateRight'] = true,
					['onNavigateUp'] = true,
					['onTab'] = true,
					['setColor'] = true,
					['setCursorPosition'] = true,
					['setFocus'] = true,
					['setFont'] = true,
					['setLine'] = true,
					['setSelectionPosition'] = true,
					['setUnderline'] = true,
					['setValue'] = true,
				},
				['inherit'] = { ['windowcontrol'] = true },
			},
		}
	end

	local apiDefinitions = getApiDefinitions()

	for object, data in pairs(apiDefinitions) do
		if not templates[simplifyObjectName(object)] or not templates[simplifyObjectName(object)].functions then
			templates[simplifyObjectName(object)] = {}
			templates[simplifyObjectName(object)].functions = {}
			templates[simplifyObjectName(object)].inherit = {}
		end
		for fn, _ in pairs(data.functions) do templates[simplifyObjectName(object)].functions[fn] = true end
		for template, _ in pairs(data.inherit) do
			templates[simplifyObjectName(object)].inherit[simplifyObjectName(template)] = true
		end
	end
end

--
-- MAIN CHUNK
--

local templates = {}
-- Iterate through package types defined in packageTypes
for _, packageTypeData in ipairs(packages) do
	print(string.format('Searching for %s', packageTypeData.name))
	findAllPackages(packageTypeData.packageList, packageTypeData.path)

	for _, packageName in ipairs(packageTypeData.packageList) do
		print(string.format('Found %s. Getting details for template search.', packageName))
		local packagePath = { datapath, packageTypeData.name, '/', packageName }
		local baseXmlFile = findBaseXml(packagePath, packageTypeData.baseFile)
		local shortPkgName = getPackageName(baseXmlFile, packageName)

		print(string.format('Finding interface XML files in %s for template search.', shortPkgName))
		local interfaceXmlFiles = {}
		findXmls(interfaceXmlFiles, baseXmlFile, packagePath)

		print(string.format('Determining templates for %s.\n', shortPkgName))
		findTemplateRelationships(templates, packagePath, interfaceXmlFiles)
		getAPIfunctions(templates)
		matchRelationshipScripts(templates)
	end

	print('Template search complete; now finding scripts.\n')
	for _, packageName in ipairs(packageTypeData.packageList) do
		print(string.format('Found %s. Getting details.', packageName))
		local packagePath = { datapath, packageTypeData.name, '/', packageName }
		local baseXmlFile = findBaseXml(packagePath, packageTypeData.baseFile)
		local shortPkgName = getPackageName(baseXmlFile, packageName)

		print(string.format('Creating definition entry %s.', shortPkgName))
		packageTypeData.definitions[shortPkgName] = {}

		print(string.format('Finding interface XML files in %s.', shortPkgName))
		local interfaceXmlFiles = {}
		findXmls(interfaceXmlFiles, baseXmlFile, packagePath)

		print(string.format('Finding interface object scripts and adding appropriate templates for %s.', shortPkgName))
		findInterfaceScripts(
						packageTypeData.definitions[shortPkgName], templates, interfaceXmlFiles,
						{ datapath, packageTypeData.name, '/', packageName }
		)

		print(string.format('Finding named scripts in %s.', shortPkgName))
		findNamedLuaScripts(packageTypeData.definitions[shortPkgName], baseXmlFile, packagePath)

		print(string.format('Writing definitions for %s.\n', shortPkgName))
		writeDefinitionsToFile(packageTypeData.definitions, shortPkgName)
	end
end
