#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { pipeline } = require('stream/promises');

async function decryptFile(srcPath, destPath) {
  await fs.promises.mkdir(path.dirname(destPath), { recursive: true });
  await pipeline(
    fs.createReadStream(srcPath, { highWaterMark: 16384 }),
    fs.createWriteStream(destPath)
  );
}

async function decryptDirectory(srcDir, destDir) {
  await fs.promises.mkdir(destDir, { recursive: true });
  for (const item of await fs.promises.readdir(srcDir, { withFileTypes: true })) {
    const src = path.join(srcDir, item.name);
    const dest = path.join(destDir, item.name);
    if (item.isDirectory() && item.name !== 'node_modules') {
      await decryptDirectory(src, dest);
    } else if (item.isFile()) {
      await decryptFile(src, dest);
    }
  }
}

function findEncryptedFiles(dir) {
  const escaped = dir.replace(/'/g, "''");
  const script = [
    "$ProgressPreference = 'SilentlyContinue'",
    '[Console]::OutputEncoding = [Text.Encoding]::UTF8',
    `$files = @(Get-ChildItem -LiteralPath '${escaped}' -Recurse -File -Force | ForEach-Object {`,
    '  $stream = $null',
    '  try {',
    '  $b = New-Object byte[] 26',
    '  $stream = [IO.File]::OpenRead($_.FullName)',
    '  $n = $stream.Read($b, 0, 26)',
    '  if ($n -eq 26 -and $b[0] -eq 0x89 -and $b[1] -eq 0x7D -and $b[2] -eq 0x1C -and ($b[4] -eq 0x25 -or $b[4] -eq 0x40) -and $b[5] -eq 0x00 -and $b[6] -eq 0x0F -and $b[7] -eq 0x00 -and $b[20] -eq 0xC4 -and $b[21] -eq 0x6C -and $b[22] -eq 0x14 -and $b[23] -eq 0x06 -and $b[24] -eq 0xFE -and $b[25] -eq 0xFF) { $_.FullName }',
    '  } catch { [Console]::Error.WriteLine("读取失败: " + $_.Exception.Message) }',
    '  finally { if ($null -ne $stream) { $stream.Dispose() } }',
    '})',
    'ConvertTo-Json -InputObject $files -Compress'
  ].join('\n');
  const encoded = Buffer.from(script, 'utf16le').toString('base64');
  const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'inherit']
  });
  return JSON.parse(out.replace(/^\uFEFF/, '').trim());
}

async function unlockInPlace(src) {
  let tmp = path.join(path.dirname(src), `unlock_${path.basename(src)}`);
  if (fs.existsSync(tmp)) {
    tmp = path.join(path.dirname(src), `unlock_${require('crypto').randomUUID()}_${path.basename(src)}`);
  }
  await decryptFile(src, tmp);
  fs.rmSync(src, { force: true });
  fs.renameSync(tmp, src);
}

async function unlockDirectory(dir) {
  console.log('正在扫描加密文件…');
  const files = findEncryptedFiles(dir);
  console.log(`找到加密文件 ${files.length} 个`);
  let failed = 0;
  let completed = 0;
  const interactive = process.stdout.isTTY;
  const readline = require('readline');
  function progress(file) {
    const ratio = files.length ? completed / files.length : 1;
    const width = 24;
    const filled = Math.floor(ratio * width);
    const bar = '█'.repeat(filled) + '░'.repeat(width - filled);
    const label = file ? path.basename(file) : '完成';
    const line = `  [${bar}] ${String(Math.round(ratio * 100)).padStart(3)}%  ${completed}/${files.length}  ${label}`;
    if (interactive) {
      readline.cursorTo(process.stdout, 0);
      readline.clearLine(process.stdout, 0);
      // 按显示宽度截断，避免中文文件名导致进度条换行。
      let output = '';
      let columns = 0;
      const limit = Math.max(1, (process.stdout.columns || 100) - 1);
      for (const char of line) {
        columns += char.codePointAt(0) > 0xFF ? 2 : 1;
        if (columns > limit) break;
        output += char;
      }
      process.stdout.write(`\x1b[36m${output}\x1b[0m`);
    } else {
      console.log(line);
    }
  }
  for (const file of files) {
    progress(file);
    try {
      await unlockInPlace(file);
    } catch (error) {
      failed++;
      if (interactive) process.stdout.write('\n');
      console.error(`处理失败: ${file}: ${error.message}`);
    }
    completed++;
  }
  progress();
  if (interactive) process.stdout.write('\n');
  console.log(`文件夹处理完成: 成功 ${files.length - failed}，失败 ${failed}`);
  if (failed) process.exitCode = 1;
}

function showHelp() {
  console.log(`
用法: unlock <源路径> [目标路径]

参数:
  源路径    要解密的文件或目录路径
  目标路径  解密后文件保存的路径（可选）
            文件未指定目标时，原位解密，保持原路径和文件名
            文件夹未指定目标时，递归识别加密文件并原位解密

示例:
  unlock ./encrypted-file.txt
  unlock ./encrypted-file.txt ./encrypted-file.txt
  unlock ./encrypted-dir/
  unlock ./encrypted-dir/ ./decrypted-dir/
  `);
}

async function main() {
  const args = process.argv.slice(2);
  
  if (args.length === 0 || args.includes('-h') || args.includes('--help')) {
    showHelp();
    process.exit(0);
  }
  
  const srcPath = args[0];
  let destPath = args[1];
  
  if (!fs.existsSync(srcPath)) {
    console.error(`错误: 源路径 "${srcPath}" 不存在`);
    process.exit(1);
  }

  if (!destPath && fs.statSync(srcPath).isDirectory()) {
    try {
      await unlockDirectory(path.resolve(srcPath));
    } catch (error) {
      console.error(`解密过程中出现错误: ${error.message}`);
      process.exit(1);
    }
    return;
  }
  
  // 文件未指定目标路径时，默认原位解密
  if (!destPath) {
    destPath = srcPath;
  }

  const sameTarget = path.resolve(srcPath) === path.resolve(destPath);
  const finalDestPath = destPath;
  if (sameTarget) {
    destPath = path.join(path.dirname(path.resolve(srcPath)), `unlock_${path.basename(srcPath)}`);
  }
  
  try {
    const stat = fs.statSync(srcPath);
    
    if (stat.isFile()) {
      console.log(`正在解密文件: ${srcPath}`);
      await decryptFile(srcPath, destPath);
      console.log(`文件解密完成: ${destPath}`);
    } else if (stat.isDirectory()) {
      console.log(`正在解密目录: ${srcPath}`);
      await decryptDirectory(srcPath, destPath);
      console.log(`目录解密完成: ${destPath}`);
    }

    if (sameTarget) {
      fs.rmSync(srcPath, { recursive: true, force: true });
      fs.renameSync(destPath, finalDestPath);
      console.log(`已替换原路径: ${finalDestPath}`);
    }
  } catch (error) {
    console.error(`解密过程中出现错误: ${error.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = { main };
