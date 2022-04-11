local datapath = './.fg/'

-- Dependencies
local lfs = require('lfs') -- luafilesystem
local parseXmlFile = require('xmlparser').parseFile -- xml file parser

-- Package Types
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

	-- executes a command and returns the result as a string
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

		-- builds and returns an indexed table of lines from 'content' of parent scope.
		local function enumerateOutput()
			local lines = {}
			for line in content:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
			return lines
		end

		-- If lineConent is a match, defines the global and triggers parsing whether to redefine as a table.
		local function defineGlobal(lines, lineNumber, lineContent)

			-- Checks recursively through lines to find 'NEWTABLE'.
			-- If not found, but there is still data, it continues to the next line.
			-- If found, sets globals[globalName] as a table to allow mutating children.
			local function recursiveFindTable(globalName, prevLine)
				if lines[prevLine] and lines[prevLine]:match('NEWTABLE%s+') then
					globals[globalName] = 'table'
				elseif lines[prevLine] and
								(lines[prevLine]:match('SETTABLE%s+') or lines[prevLine]:match('SETLIST%s+') or
												lines[prevLine]:match('LOADK%s+') or lines[prevLine]:match('LOADBOOL%s+')) then
					recursiveFindTable(globalName, prevLine - 1)
				end
			end

			if lineContent:match('SETGLOBAL%s+') and not lineContent:match('%s+;%s+(_)%s*') then
				local globalName = lineContent:match('\t; (.+)%s*')
				globals[globalName] = 'global'
				recursiveFindTable(globalName, lineNumber - 1)
			end
		end

		local lines = enumerateOutput()
		for lineNumber, lineContent in ipairs(lines) do
			if lineContent:match('SETGLOBAL%s+') and not lineContent:match('%s+;%s+(_)%s*') then
				defineGlobal(lines, lineNumber, lineContent)
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

-- Write compiled defintions to globals directory for use by generate.lua.
local function writeDefinitionsToFile(defintitions, package)

	-- Rewrite definitions in format of lucheckrc, add to output, and sort output.
	local function gatherChildFunctions(output)

		-- Remove hyphens and spaces from provided string and return it.
		local function simpleName(string) return string:gsub('[%- ]', '_') end

		-- Rewrite child functions of script/object definitions in format of luacheckrc and return.
		local function writeSubdefintions(fns)
			local subdefinition = ''
			for fn, type in pairs(fns) do
				subdefinition = subdefinition .. '\t\t' .. simpleName(fn) ..
								                ' = {\n\t\t\t\tread_only = false,\n\t\t\t\tother_fields = ' .. tostring(type == 'table') ..
								                ',\n\t\t\t},\n\t'
			end

			return subdefinition
		end

		for parent, fns in pairs(defintitions[package]) do
			local simpleParent = simpleName(parent)
			if simpleParent ~= '' then
				local global =
								(simpleName(parent) .. ' = {\n\t\tread_only = false,\n\t\tfields = {\n\t' .. writeSubdefintions(fns) ..
												'\t},\n\t},')
				table.insert(output, global)
			end
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

-- Search through a supplied fantasygrounds xml file to find named lua scripts files.
local function findNamedLuaScripts(definitions, baseXmlFile, packagePath)

	-- Searches recursively for script tags within provided element.
	local function recursiveScriptSearch(element)

		-- Calls findGlobals and adds result to defintions keyed to object name.
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

				packageDefinitions[parent.attrs.name] = fns
			end
		end

		for _, element in ipairs(sheetdata.children) do
			local script = findXmlElement(element, { 'script' })
			getScriptFromXml(element, script)
			if templates[element.tag] and templates[element.tag].functions and packageDefinitions[element.attrs.name] then
				insertTableKeys(templates[element.tag].functions, packageDefinitions[element.attrs.name])
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
			packageDefinitions[element.attrs.name] = fns
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

-- Checks each template for other templates it inherits from and copies those functions into the inheriting template.
local function matchRelationshipScripts(templates)
	for _, template in pairs(templates) do
		local inheritedTemplates = template.inherit
		if inheritedTemplates then
			for inherit, _ in pairs(inheritedTemplates) do
				if inherit and templates[inherit] and templates[inherit].functions and template.functions then
					for functionName, _ in pairs(templates[inherit].functions) do template.functions[functionName] = true end
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
		local templateFunctions = {}
		if script and script.attrs.file then
			if not findGlobals(templateFunctions, table.concat(packagePath) .. '/' .. script.attrs.file) then
				findAltScriptLocation(templateFunctions, packagePath, script.attrs.file)
			end
		elseif script and script.children[1].text then
			getFnsFromLuaInXml(templateFunctions, script.children[1].text)
		end
		templates[element.attrs.name] = { ['inherit'] = { [parent.tag] = true }, ['functions'] = templateFunctions }
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

-- Find xml root node and search within for xml file definitions.
local function findXmls(xmlFiles, xmlDefinitionsPath, packagePath)

	-- Searches recursively for xml file definitions.
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

-- Adds FG API functions and in-built templates to the templates definition list.
local function getAPIfunctions(templates)
	local apiDefinitions
	if io.open('$GITHUB_ACTION_PATH/fg_apis.lua', 'w') then
		apiDefinitions = dofile('$GITHUB_ACTION_PATH/fg_apis.lua')
	else
		apiDefinitions = dofile('./fg_apis.lua')
	end

	-- Ensures that the template has the required child tables available for writing.
	local function setupTemplate(object)
		if not templates[object] or not templates[object].functions or not templates[object].functions then
			templates[object] = {}
			templates[object].functions = {}
			templates[object].inherit = {}
		end
	end

	for object, data in pairs(apiDefinitions) do
		setupTemplate(object)
		for fn, _ in pairs(data.functions) do templates[object].functions[fn] = true end
		for template, _ in pairs(data.inherit) do templates[object].inherit[template] = true end
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
	end
	getAPIfunctions(templates)
	matchRelationshipScripts(templates)

	print('Template search complete; now finding scripts.\n')
	for _, packageName in ipairs(packageTypeData.packageList) do
		print(string.format('Found %s. Getting details.', packageName))
		local packagePath = { datapath, packageTypeData.name, '/', packageName }
		local baseXmlFile = findBaseXml(packagePath, packageTypeData.baseFile)
		local shortPkgName = getPackageName(baseXmlFile, packageName)

		print(string.format('Finding interface XML files in %s.', shortPkgName))
		local interfaceXmlFiles = {}
		findXmls(interfaceXmlFiles, baseXmlFile, packagePath)

		packageTypeData.definitions[shortPkgName] = {}

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
