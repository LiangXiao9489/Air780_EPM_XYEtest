

require "sys"

PROJECT = "test_XYE_bus_protocol"
VERSION = "1.0.000"

pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

log.error("main", "====================================================")
log.error("main", "====================================================")
log.error("main", "工程名称: " .. PROJECT)
log.error("main", "固件版本: " .. VERSION)
log.error("main", "====================================================")
log.error("main", "====================================================")


sys.run()
