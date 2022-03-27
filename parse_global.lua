local function print_table(node)
  local cache, stack, output = {},{},{}
  local depth = 1
  local output_str = "{\n"

  while true do
      local size = 0
      for k,v in pairs(node) do
          size = size + 1
      end

      local cur_index = 1
      for k,v in pairs(node) do
          if (cache[node] == nil) or (cur_index >= cache[node]) then

              if (string.find(output_str,"}",output_str:len())) then
                  output_str = output_str .. ",\n"
              elseif not (string.find(output_str,"\n",output_str:len())) then
                  output_str = output_str .. "\n"
              end

              -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
              table.insert(output,output_str)
              output_str = ""

              local key
              if (type(k) == "number" or type(k) == "boolean") then
                  key = "["..tostring(k).."]"
              else
                  key = "['"..tostring(k).."']"
              end

              if (type(v) == "number" or type(v) == "boolean") then
                  output_str = output_str .. string.rep('\t',depth) .. key .. " = "..tostring(v)
              elseif (type(v) == "table") then
                  output_str = output_str .. string.rep('\t',depth) .. key .. " = {\n"
                  table.insert(stack,node)
                  table.insert(stack,v)
                  cache[node] = cur_index+1
                  break
              else
                  output_str = output_str .. string.rep('\t',depth) .. key .. " = '"..tostring(v).."'"
              end

              if (cur_index == size) then
                  output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
              else
                  output_str = output_str .. ","
              end
          else
              -- close the table
              if (cur_index == size) then
                  output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
              end
          end

          cur_index = cur_index + 1
      end

      if (size == 0) then
          output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
      end

      if (#stack > 0) then
          node = stack[#stack]
          stack[#stack] = nil
          depth = cache[node] == nil and depth + 1 or depth - 1
      else
          break
      end
  end

  -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
  table.insert(output,output_str)
  output_str = table.concat(output)

  print(output_str)
end

-- Config
local luacCommand = 'luac'
local datapath = './.fg/'
local globals_suffix = 'globals'

-- Datatypes
local packageTypes = {
  ['rulesets'] = { datapath .. 'rulesets/', 'base.xml' },
  ['extensions'] = { datapath .. 'extensions/', 'extension.xml', { 'author', 'name' } },
}

-- Core
local lfs = require('lfs')

local function findAllPackages(path)
  local result = {}

  lfs.mkdir(path)
  for file in lfs.dir(path) do
    local fileType = lfs.attributes(path .. '/' .. file, 'mode')
    if fileType == 'directory' then
      if file ~= '.' and file ~= '..' then
        table.insert(result, file)
      end
    end
  end

  return result
end

local function executeCapture(command)
  local file = assert(io.popen(command, 'r'))
  local str = assert(file:read('*a'))
  str = string.gsub(str, '^%s+', '')
  str = string.gsub(str, '%s+$', '')

  file:close()
  return str
end

local function findBaseXml(path, searchName)
  for file in lfs.dir(path) do
    local fileType = lfs.attributes(path .. '/' .. file, 'mode')
    if fileType == 'file' and string.find(file, searchName) then
      return path .. '/' .. file
    end
  end
end

local function findHighLevelScripts(baseXmlFile)
  local fhandle = io.open(baseXmlFile, 'r')
  local data = fhandle:read("*a")

  local scripts = {}
  for line in string.gmatch(data, '[^\r\n]+') do
    if string.match(line, '<script.+/>') and not string.match(line, '<!--.*<script.+/>.*-->') then
      local sansRuleset = line:gsub('ruleset=".-"%s+', '')
      local fileName, filePath = sansRuleset:match('<script%s+name="(.+)"%s+file="(.+)"%s*/>')
      if fileName then
        scripts[fileName] = filePath
      end
    end
  end

  fhandle:close()
  return scripts
end

local function addScriptToArray(scripts, path, filename, parentControlName)
  local fullPath = (path .. '/' .. filename):gsub("\\", '/')
  --print(parentControlName, fullPath)
  if io.open(fullPath, 'r') then
    if scripts[parentControlName] then
      table.insert(scripts[parentControlName], fullPath)
    else
      scripts[parentControlName] = { fullPath }
    end
  else
    fullPath = (datapath .. 'rulesets/CoreRPG/' .. filename):gsub("\\", '/')
    if scripts[parentControlName] then
      table.insert(scripts[parentControlName], fullPath)
    else
      scripts[parentControlName] = { fullPath }
    end
  end
end

local parseFile = require('xmlparser').parseFile
local function findScriptsInXml(scripts, path, e, parentControl, grandparentControl, grandparentControlIndex)
  if e.tag then
    if parentControl and e.attrs.file and e.attrs.file:find('.lua') then
      local parentControlName = parentControl.attrs.name
        if grandparentControl then
          local grandparentControlName = grandparentControl.attrs.name
          addScriptToArray(scripts, path, grandparentControl['children'][1]['children'][grandparentControlIndex]['attrs']['file'], grandparentControl.attrs.name)
        end
        addScriptToArray(scripts, path, e.attrs.file, parentControlName)
      end

    local control
    --print_table(e.attrs)
    --for _,attr in ipairs(e.orderedattrs) do
    --  if attr.name == 'name' or attr.name == 'file' then
    --    control = attr
    --  end
    --end
    if e.attrs.name or e.attrs.file then
      control = e
    end
    for index, child in ipairs(e.children) do
      findScriptsInXml(scripts, path, child, control, parentControl, index)
    end
  end
end
local function findTemplatesInXml(scripts, path, e, parentControlName)
  if e and e.tag then
    if parentControlName then
      for _, child in ipairs(e.children) do
        if child.tag == 'script' and child.attrs and child.attrs.file then
          local fullPath = (path .. '/' .. child.attrs.file):gsub("\\", '/')
          if io.open(fullPath, 'r') then
            if scripts[parentControlName] then
              table.insert(scripts[parentControlName], fullPath)
            else
              scripts[parentControlName] = { fullPath }
            end
          else
            fullPath = (datapath .. 'rulesets/CoreRPG/' .. child.attrs.file):gsub("\\", '/')
            if scripts[parentControlName] then
              table.insert(scripts[parentControlName], fullPath)
            else
              scripts[parentControlName] = { fullPath }
            end
          end
        end
      end
    end
    local controlName
    if e.tag == 'template' then
      for _,attr in ipairs(e.orderedattrs) do
        if attr.name == 'name' then
          controlName = attr.value
        end
      end
    end
    for _, child in ipairs(e.children) do
      findTemplatesInXml(scripts, path, child, controlName)
    end
  end
end

local function findInterfaceScripts(path, xmlFile)
  local scripts = {}

  for _, xmlEntry in pairs(parseFile(xmlFile).children) do
    findScriptsInXml(scripts, path, xmlEntry)
  end

  for _, xmlEntry in pairs(parseFile(xmlFile).children) do
    findTemplatesInXml(scripts, path, xmlEntry)
  end

  return scripts
end

local function findInterfaceXmls(path, searchName)
  local baseXmlFile = findBaseXml(path, searchName)

  local fhandle = io.open(baseXmlFile, 'r')
  local data = fhandle:read("*a")

  local xmlFiles = {}
  for line in data:gmatch('[^\r\n]+') do
    if line:match('<includefile.+/>') and not line:match('<!--.*<includefile.+/>.*-->') then
      local sansRuleset = line:gsub('ruleset=".-"%s+', '')
      local filePath  = sansRuleset:match('<includefile%s+source="(.+)"%s*/>') or ''
      local fileName = filePath:match('.+/(.-).xml') or filePath:match('(.-).xml')
      if fileName then
        xmlFiles[fileName] = path .. '/' .. filePath
      end
    end
  end

  fhandle:close()
  return xmlFiles
end

local function findGlobals(output, parent, luac, file)
  executeCapture('perl -e \'s/\\xef\\xbb\\xbf//;\' -pi ' .. file)
  local content = executeCapture(string.format('%s -l -p ' .. file, luac))

  for line in content:gmatch('[^\r\n]+') do
    if line:match('SETGLOBAL%s+') and
    not line:match('%s+;%s+(_)%s*') then
      local variable = (
        '\t\t' ..
        line:match('\t; (.+)%s*') ..
        ' = {\n' ..
        '\t\t\t\tread_only = false,\n\t\t\t\tother_fields = false,' ..
        '\n\t\t\t},\n'
      )
      if not output[parent] then
        output[parent] = variable
      elseif not string.find(output[parent], '\t' .. variable .. '\t') then
        output[parent] = output[parent] .. '\t' .. variable
      end
    end
  end

  return output
end

local function getAltPackageName(packagePath, altPackageNameCriteria, searchName)
  local baseXmlFile = findBaseXml(packagePath, searchName)

  local altNameData = {}
    for _, root in pairs(parseFile(baseXmlFile).children) do
      if root.tag then
        for _, entry in ipairs(root.children) do
          if entry.tag == 'properties' then
            for _, value in ipairs(entry.children) do
              for _, altPackageNameCriterion in ipairs(altPackageNameCriteria) do
                if value.tag == altPackageNameCriterion then
                  local altName = value.children[1]['text']
                  altName = altName:gsub('.*: ', ''):gsub('%(.*%)', '')
                  altNameData[altPackageNameCriterion] = altName
                end
                if not altNameData[altPackageNameCriterion] then
                  altNameData[altPackageNameCriterion] = ''
                end
              end
            end
          end
        end
      end
    end
    return altNameData['author'] .. altNameData['name']
end

for packageTypeName, packageType in pairs(packageTypes) do
  local packageList = findAllPackages(packageType[1])
  table.sort(packageList)

  print(string.format("Searching for %s", packageTypeName))
  lfs.mkdir(datapath .. packageTypeName .. globals_suffix .. '/')
  for _, packageName in pairs(packageList) do
    local packageLocation = datapath .. packageTypeName .. '/'
    local packagePath = packageLocation .. packageName
    print(string.format("Searching %s files for globals", packageName))

    local currentBranch = executeCapture(
      string.format(
        'git -C %s branch --show-current', packagePath
      )
    )

    local formattedPackageName = packageName
    if packageType[3] then
      formattedPackageName = getAltPackageName(packagePath, packageType[3], packageType[2]) or ''
    end
    formattedPackageName = formattedPackageName:gsub('[^%a%d%.]+', '')
    if string.sub(formattedPackageName, 1, 1):match('%d') then
      formattedPackageName = 'def' .. formattedPackageName
    end
    print(
      string.format(
      "Currently generating stds definition for %s@%s", formattedPackageName, currentBranch
      )
    )
    local destFilePath = (
      datapath ..
      packageTypeName ..
      globals_suffix ..
      '/' ..
      formattedPackageName ..
      globals_suffix ..
      '.lua'
    )

    local destFile = assert(
      io.open(destFilePath, 'w'), "Error opening file " .. destFilePath)

    local baseXmlFile = findBaseXml(packagePath, packageType[2])
    local highLevelScripts = findHighLevelScripts(baseXmlFile)
    local contents = {}
    for parent, filePath in pairs(highLevelScripts) do
      --print(string.format("Handling file %s", filePath))
      findGlobals(contents, parent, luacCommand, packageType[1] .. packageName .. '/' .. filePath)
    end

    local interfaceScripts = findInterfaceXmls(packagePath, packageType[2])
    for _, xmlPath in pairs(interfaceScripts) do
      local xmlScripts = findInterfaceScripts(packagePath, xmlPath)
      for windowObject, filePaths in pairs(xmlScripts) do
        for _, filePath in ipairs(filePaths) do
          --print(string.format("Handling %s script at %s", windowObject, filePath))
          findGlobals(contents, windowObject, luacCommand, filePath)
        end
      end
    end

    local output = {}
    for parent, var in pairs(contents) do
      local global = (
        parent .. ' = {\n\t\tread_only = false,\n\t\tfields = {\n\t' .. var .. '\t\t},\n\t},'
      )
      table.insert(output, global)
    end
    table.sort(output)

    destFile:write('globals = {\n')
    for _, var in ipairs(output) do
      destFile:write('\t' .. var .. '\n')
    end

    destFile:write('}\n')
    destFile:close()
  end
end
