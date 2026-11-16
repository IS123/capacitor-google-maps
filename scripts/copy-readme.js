// Cross-platform replacement for `cp ./plugin/README.md ./README.md`.
const { copyFileSync } = require('node:fs');
const { resolve } = require('node:path');

const root = resolve(__dirname, '..');
copyFileSync(resolve(root, 'plugin/README.md'), resolve(root, 'README.md'));
