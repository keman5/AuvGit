import { writeFile } from 'node:fs/promises';
import path from 'node:path';
// A disposable app-server double: exercises the real JSON-lines transport.
export async function projectFixture(directory, projects) {
  const file = path.join(directory, 'codex-fixture');
  await writeFile(file, '#!' + process.execPath + '\n' + `
const {createInterface}=require('node:readline');
const pages=${JSON.stringify(projects)};
createInterface({input:process.stdin}).on('line',line=>{
 const req=JSON.parse(line); if(req.id===undefined)return;
 const result=req.method==='initialize'?{userAgent:'fixture'}:req.method==='project/list'?{data:pages.slice(Number(req.params.cursor||0),Number(req.params.cursor||0)+2),nextCursor:Number(req.params.cursor||0)+2<pages.length?String(Number(req.params.cursor||0)+2):null}:{};
 process.stdout.write(JSON.stringify({id:req.id,result})+'\\n');
});\n`, { mode: 0o755 });
  return file;
}
