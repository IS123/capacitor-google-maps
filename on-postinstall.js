const fs = require('fs');
const path = require('path');

const pluginPackageJson = JSON.parse(fs.readFileSync('./plugin/package.json', 'utf8'));

function ensureDirectoryExists(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function isDirectory(sourcePath) {
  return fs.existsSync(sourcePath) && fs.statSync(sourcePath).isDirectory();
}
function copyDir(src, dest) {
  ensureDirectoryExists(dest);
  const entries = fs.readdirSync(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

function copyFileOrDir(sourcePath, destPath) {
  const fullSourcePath = path.join('plugin', sourcePath);
  
  const parentDir = path.dirname(destPath);
  ensureDirectoryExists(parentDir);
  
  if (isDirectory(fullSourcePath)) {
    console.log(`Copying directory: ${fullSourcePath} -> ${destPath}`);
    copyDir(fullSourcePath, destPath);
  } else {
    console.log(`Copying file: ${fullSourcePath} -> ${destPath}`);
    fs.copyFileSync(fullSourcePath, destPath);
  }
}

function copyPluginFiles() {
  console.log('Copying plugin files to root directory...');
  
  const filesToCopy = pluginPackageJson.files || [];
  
  filesToCopy.forEach(filePath => {
    // Remove trailing slashes if present
    const cleanPath = filePath.replace(/\/$/, '');
    
    const destPath = cleanPath;
    
    copyFileOrDir(cleanPath, destPath);
  });
  
  if (fs.existsSync('plugin/README.md')) {
    console.log('Copying README.md');
    fs.copyFileSync('plugin/README.md', 'README.md');
  }
  
  console.log('Files copied successfully!');
}

copyPluginFiles();
