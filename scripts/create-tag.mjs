// Builds dist and creates a release tag for it WITHOUT committing dist to
// the current branch. The build output is committed into a one-off commit
// on top of the current HEAD, tagged, and only the tag is pushed. The
// local branch is then reset back to its original state, so dist never
// lives on master history - it only exists under the tag.
import { execSync, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(rootDir);

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const tagArg = args.filter((a) => a !== '--dry-run' && a !== '--').pop() ?? '';

const git = (cmd) => execSync(`git ${cmd}`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const run = (cmd) => execSync(cmd, { stdio: 'inherit' });
const fail = (msg) => {
  console.error(msg);
  process.exit(1);
};

if (git('status --porcelain')) {
  fail('Working tree is not clean. Commit or stash your changes first.');
}

const currentBranch = git('rev-parse --abbrev-ref HEAD');
const currentCommit = git('rev-parse HEAD');

const tag = tagArg || `v${JSON.parse(readFileSync('package.json', 'utf8')).version}`;

const tagExists = (t) => {
  if (spawnSync('git', ['rev-parse', '-q', '--verify', `refs/tags/${t}`], { stdio: 'ignore' }).status === 0) return true;
  return spawnSync('git', ['ls-remote', '--exit-code', '--tags', 'origin', t], { stdio: 'ignore' }).status === 0;
};

if (tagExists(tag)) {
  console.error(`Tag ${tag} already exists (locally or on origin).`);
  const prefix = tag.split('-')[0];
  console.error(`Last 5 tags matching ${prefix}*:`);
  console.error(git(`tag -l "${prefix}*" --sort=-creatordate`).split('\n').slice(0, 5).join('\n'));
  process.exit(1);
}

console.log('==> Building dist');
run('pnpm run build');

console.log('==> Copying plugin files to root (prepare)');
run('npm run copy:plugin');

console.log(`==> Committing build artifacts locally (will not be pushed to ${currentBranch})`);
run('git add -f dist plugin/dist android ios CapacitorGoogleMaps.podspec README.md');
run(`git commit --quiet -m "chore: build dist for ${tag}"`);

console.log('');

if (dryRun) {
  console.log(`Dry run: not creating tag or pushing. Restoring ${currentBranch}.`);
  run(`git reset --hard ${currentCommit}`);
  process.exit(0);
}

console.log(`==> Tagging ${tag}`);
run(`git tag -a "${tag}" -m "${tag}"`);

console.log(`==> Pushing tag ${tag} (branch ${currentBranch} is not pushed)`);
run(`git push origin "${tag}"`);

console.log(`==> Restoring ${currentBranch} to its original state (build commit stays only under the tag)`);
run(`git reset --hard ${currentCommit}`);

console.log('\nDone');
