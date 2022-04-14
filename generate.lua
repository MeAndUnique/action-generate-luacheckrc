-- Config
local dataPath = './.fg/'

local stdBase = '[selene.base]\nbase = "lua51"\nname = "fantasygrounds"'
local stdString = arg[1] or ''
local headerFileName = arg[2] or 'fglualibrary_header.toml'
local outputFile = arg[3] or 'fglualibrary.toml'

-- Datatypes
local packageTypes = {
	['rulesets'] = { dataPath .. 'rulesetsglobals/', 'base.xml' },
	['extensions'] = { dataPath .. 'extensionsglobals/', 'extension.xml' },
}

-- Core
local lfs = require('lfs')

-- open new luachecrc file for writing and post error if not possible
local destFile = assert(io.open(outputFile, 'w'), 'Error opening file ' .. outputFile)

-- add selene meta info to luachecrc file
destFile:write(stdBase .. '\n' .. stdString .. '\n\n')

-- open header file and add to top of new config file
local headerFile = io.open(headerFileName, 'r')
if headerFile then
	destFile:write(headerFile:read('*a'))
	headerFile:close()
end

-- returns a list of files ending in globals.lua
local function findPackageFiles(path)
	local result = {}

	for file in lfs.dir(path) do
		local fileType = lfs.attributes(path .. '/' .. file, 'mode')
		local packageName = string.match(file, '(.*)globals.lua')
		if packageName and fileType == 'file' then if file ~= '.' and file ~= '..' then result[packageName] = path .. '/' .. file end end
	end

	return result
end

-- looks through each package type's detected globals
-- it then appends them to the config file
for _, packageType in pairs(packageTypes) do
	local packageFiles = findPackageFiles(packageType[1])
	for packageName, file in pairs(packageFiles) do
		local stdsName = ('# ' .. packageName:lower() .. ' definitions\n')
		destFile:write(stdsName)
		local fhandle = io.open(file, 'r')
		local content = fhandle:read('*a')
		for line in string.gmatch(content, '[^\r\n]+') do destFile:write(line .. '\n') end
		destFile:write('\n')
	end
end

destFile:close()
