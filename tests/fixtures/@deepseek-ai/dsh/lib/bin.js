// Test-only process that looks like `dsh web` and owns the requested port.
const net = require('node:net')
const index = process.argv.indexOf('--port')
if (index < 0 || !process.argv[index + 1]) process.exit(2)
const port = Number(process.argv[index + 1])
const server = net.createServer(() => {})
server.listen(port, '127.0.0.1')

