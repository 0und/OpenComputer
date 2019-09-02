log = {
	
}
function log.open(fileName)
	log.file = io.open(fileName, 'a')
end
function log.log(str)
	log.file:write('['..os.date('%c')..'] '..str..'\n')
end
