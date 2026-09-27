import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

// The TypeScript parser is a development tool, never a native runtime dependency.
const [sourceRoot, referenceRoot, outputRoot, treePath] = process.argv.slice(2);
if (!treePath) throw new Error('Usage: node tool/upstream_inventory.mjs SOURCE REFERENCE OUTPUT GITHUB_TREE_JSON');
const require = createRequire(path.resolve(referenceRoot, 'package.json'));
const ts = require('typescript');
const root = path.resolve(sourceRoot);
const revision = 'b012ad06d858fc035d88aacfd73f092f93c994e4';
const tree = JSON.parse(fs.readFileSync(treePath, 'utf8'));
if (tree.sha !== revision || tree.truncated) throw new Error('Wrong or incomplete upstream tree');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const walk = dir => fs.readdirSync(path.join(root, dir), { withFileTypes: true })
  .flatMap(item => item.isDirectory() ? walk(`${dir}/${item.name}`) : [`${dir}/${item.name}`]);
const files = walk('.').map(file => file.slice(2)).sort();
const blobs = new Map(tree.tree.filter(item => item.type === 'blob').map(item => [item.path, item.sha]));
const hashes = files.map(file => {
  const bytes = fs.readFileSync(path.join(root, file));
  const sha = crypto.createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
  if (blobs.get(file) !== sha) throw new Error(`Source differs from pinned revision: ${file}`);
  return { path: file, gitBlob: sha, bytes: bytes.length };
});
if (files.length !== blobs.size) throw new Error('Source files missing');
const parse = file => ts.createSourceFile(file, read(file), ts.ScriptTarget.Latest, true);
const line = (source, node) => source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
const exported = node => node.modifiers?.some(modifier => modifier.kind === ts.SyntaxKind.ExportKeyword);
const names = name => ts.isIdentifier(name) ? [name.text] : name.elements.flatMap(item => names(item.name));
function members(source, node) {
  return (node.members ?? []).filter(item => !item.modifiers?.some(modifier =>
    modifier.kind === ts.SyntaxKind.PrivateKeyword || modifier.kind === ts.SyntaxKind.ProtectedKeyword))
    .map(item => ({ name: item.name?.getText(source) ?? 'constructor', line: line(source, item), kind: ts.SyntaxKind[item.kind] }));
}
const modules = files.filter(file => /^packages\/[^/]+\/src\/.*\.(ts|tsx)$/.test(file) && !file.endsWith('.test.ts'))
  .map(file => {
    const source = parse(file), declarations = [], reexports = [];
    for (const node of source.statements) {
      if (ts.isExportDeclaration(node)) {
        reexports.push({ line: line(source, node), declaration: node.getText(source) });
      } else if (exported(node)) {
        if (ts.isVariableStatement(node)) {
          for (const declaration of node.declarationList.declarations) {
            for (const name of names(declaration.name)) declarations.push({ name, line: line(source, declaration), kind: 'VariableDeclaration' });
          }
        } else if (node.name) {
          declarations.push({ name: node.name.text, line: line(source, node), kind: ts.SyntaxKind[node.kind], members: members(source, node) });
        }
      }
    }
    return { path: file, declarations, reexports };
  });
const entrypoints = files.filter(file => /^packages\/[^/]+\/package.json$/.test(file)).map(file => {
  const pkg = JSON.parse(read(file));
  return { name: pkg.name, version: pkg.version, path: file, exports: Object.keys(pkg.exports) };
});
const stories = files.filter(file => /\.stories\.(ts|tsx)$/.test(file)).flatMap(file => {
  const source = parse(file);
  const title = /title:\s*['"]([^'"]+)['"]/.exec(source.text)?.[1];
  return source.statements.filter(node => exported(node) && ts.isVariableStatement(node))
    .flatMap(node => node.declarationList.declarations.flatMap(declaration => names(declaration.name)
      .map(name => ({ path: file, line: line(source, declaration), title, name, nativeStatus: 'missing', comparison: 'not run' }))));
});
const imports = files.filter(file => /^(storybook|storybook-webgpu|examples|apps)\/.*\.(ts|tsx)$/.test(file))
  .flatMap(file => {
    const source = parse(file);
    return source.statements.filter(ts.isImportDeclaration).map(node => ({
      path: file, line: line(source, node), module: node.moduleSpecifier.text, bindings: node.importClause?.getText(source)
    }));
  });
const inventory = { schema: 1, repository: 'takram-design-engineering/three-geospatial', revision,
  verification: 'All supplied files match the Git blob hashes in the pinned upstream tree.',
  entrypoints, files: hashes, modules, stories, imports };
fs.mkdirSync(outputRoot, { recursive: true });
fs.writeFileSync(path.join(outputRoot, 'inventory.json'), JSON.stringify(inventory, null, 2) + '\n');
const link = (file, line) => `https://github.com/takram-design-engineering/three-geospatial/blob/${revision}/${file}${line ? '#L' + line : ''}`;
const text = ['# Upstream export and story catalog', '',
  `Source revision: \`${revision}\`. All ${files.length} supplied files match.`, '',
  'Run `tool/upstream_inventory.mjs` to regenerate this catalog. The JSON also records public class members, type declarations, re-export statements, integration imports and every file hash. An exported helper in a source module is included even when a package entrypoint does not expose it.', '',
  'This catalog defines source coverage. Implementation and verification live in [the parity matrix](matrix.md); presence here does not establish native support.', '',
  '## Packages', '', '| Package | Version | Entrypoints |', '| --- | --- | --- |',
  ...entrypoints.map(pkg => `| ${pkg.name} | ${pkg.version} | ${pkg.exports.join(', ')} |`), '',
  '## Exported declarations', '', '| Source | Declarations | Re-exports |', '| --- | --- | --- |',
  ...modules.filter(module => module.declarations.length || module.reexports.length).map(module =>
    `| [${module.path}](${link(module.path)}) | ${module.declarations.map(item => item.name).join(', ')} | ${module.reexports.length} |`), '',
  '## Stories', '', '| Source | Story group | Export | Native comparison |', '| --- | --- | --- | --- |',
  ...stories.map(story => `| [${story.path}:${story.line}](${link(story.path, story.line)}) | ${story.title ?? ''} | ${story.name} | Not run |`), ''];
fs.writeFileSync(path.join(outputRoot, 'catalog.md'), text.join('\n'));
console.log(JSON.stringify({ files: files.length, modules: modules.length, declarations: modules.reduce((sum, m) => sum + m.declarations.length, 0), stories: stories.length }));
