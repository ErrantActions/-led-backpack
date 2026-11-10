import assert from 'node:assert/strict';
import {readFile,readdir,access} from 'node:fs/promises';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Script} from 'node:vm';
import {createHash} from 'node:crypto';

const root=dirname(fileURLToPath(import.meta.url));
const text=path=>readFile(join(root,path),'utf8');
const json=async path=>JSON.parse(await text(path));
const references=await json('screenshots\\app-references.json');
const board=await text('screenshots\\app-reference-board.html');
const atlas=await text('layouts\\design-atlas.html');
const messaging=await text('layouts\\messaging.html');
const messagingProof=await json('layouts\\messaging-validation.json');
const data=await json('layouts\\design-atlas-data.json');
const design=await json('layouts\\led-backpack.layout.json');
const pages=await json('layouts\\page-designs.json');
const validation=await json('layouts\\design-validation.json');
const native=await json('layouts\\native-source-refresh.json');
const simplification=await json('layouts\\interaction-simplification.json');
const embedded=(html,id)=>JSON.parse(html.match(new RegExp(`<script id="${id}" type="application/json">([\\s\\S]*?)</script>`))[1]);
assert.deepEqual(embedded(board,'reference-data'),references);
assert.deepEqual(embedded(atlas,'atlas-data'),data);
assert.equal(messagingProof.status,'passed');
assert.equal(messagingProof.source.sha256,createHash('sha256').update(messaging).digest('hex'),
  'Messaging prototype changed: repeat browser verification and update its proof.');
assert.equal(messagingProof.behaviorChecks,50);
assert.equal(messagingProof.groups.reduce((n,g)=>n+g.checks.length,0),messagingProof.behaviorChecks);
const messagingGeometry=messagingProof.geometry;
assert.equal(messagingGeometry.cases,messagingGeometry.requestedViewportWidths.length*
  messagingGeometry.requestedViewportHeights.length*messagingGeometry.layouts.length*messagingGeometry.views.length);
for(const key of ['failures','horizontalOverflowCases','clippedStructuralContainers',
  'composerOutsideAppCases','undersizedVisibleControlCases'])assert.equal(messagingGeometry[key],0);
assert.ok(messagingGeometry.minimumVisibleControlSize>=44);
assert.equal(messagingGeometry.wideSplitCases+messagingGeometry.compactFallbackCases,messagingGeometry.cases);
assert.deepEqual(messagingProof.additionalChecks.historyScrollPositionsBeforeFoldAndReopen,[120,120,120]);
assert.equal(messagingProof.additionalChecks.externalRequestsObserved,0);
for(const key of ['reduceMotionStopsBubbleEntrance','systemMotionPreferenceRestored',
  'directAndRoomActionsRemainDistinct','atlasMessagingLinkNavigated'])assert.equal(messagingProof.additionalChecks[key],true);
assert.equal(references.apps.length,44);
assert.equal(new Set(references.apps.map(a=>a.id)).size,44);
assert.equal(references.apps.reduce((n,a)=>n+a.screenshots.length,0),312);
assert.equal(data.pages.length,202);
assert.equal(data.variations.length,10);
assert.equal(design.screens.length,244);
assert.equal(design.name,'LED Backpack');
assert.equal(design.screens.filter(s=>!s.elements.length&&s.reference).length,42);
assert.equal(validation.layoutCases,2020);
assert.deepEqual(validation.issues,[]);
assert.equal(validation.browserChecks.renderedStudies,202);
assert.equal(validation.browserChecks.renderFailures,0);
assert.equal(validation.browserChecks.renderedLayoutCases,2020);
assert.equal(validation.browserChecks.clippedTextCases,0);
assert.equal(validation.themeReview.browserVerification,'passed');
for(const key of ['movingPixelsChanged','pauseStopsFrames','reduceMotionStaticArt','hiddenArtworkStopsFrames','navigationDisposesOldClock'])
  assert.equal(validation.themeReview[key],true);
assert.equal(validation.portableProposal.decoded,true);
assert.equal(validation.portableProposal.elements,design.screens.reduce((n,s)=>n+s.elements.length,0));
assert.equal(validation.liveReadback.portableExportDecoded,true);
assert.ok(validation.contrast.every(p=>p.ratio>=4.5));
assert.equal(native.covered,native.nativeSurfaces);
assert.deepEqual(native.missing,[]);
assert.equal(native.refreshedStudies.length,13);
const byId=new Map(design.screens.map(s=>[s.id,s]));
for(const p of data.pages){
  assert.ok(byId.has(p.id));
  const screen=byId.get(p.id);
  assert.equal(p.background,screen.background);
  assert.equal(new Set(p.elements.map(e=>e.id)).size,p.elements.length);
  for(const e of p.elements){
    const source=screen.elements.find(s=>s.id===e.id);
    assert.ok(source&&!source.hidden);
    for(const key of ['type','text','symbol','fill','color','fontSize','radius','action','target'])
      assert.equal(e[key],source[key],`${p.name}/${e.name}: stale ${key}`);
    assert.equal(e.asset,source.asset.startsWith('data:image/png;')?source.asset:'');
  }
  assert.equal(Object.keys(p.views).length,10);
  for(const view of Object.values(p.views)){
    assert.ok(view.width>0&&view.height>0);
    for(const frame of view.elements)assert.ok(p.elements.some(e=>e.id===frame.id),`${p.name}: missing preview control`);
  }
}
assert.deepEqual(new Set(data.pages.map(p=>p.id)),new Set(pages.pages.map(p=>p.id)));
for(const m of native.sourceMap){
  const e=byId.get(m.screenId)?.elements.find(e=>e.id===m.elementId);
  assert.ok(e,`Missing current-source element: ${m.elementId}`);
  assert.equal(e.hidden,Boolean(m.designHidden),`Unrecorded source visibility change: ${m.elementId}`);
}
assert.equal(simplification.typedConfirmationReplacements,5);
assert.equal(simplification.artworkNameInputsRemoved,8);
for(const c of simplification.changes.filter(c=>c.kind==='hidden-artwork-name-input'))
  assert.equal(byId.get(c.screenId).elements.find(e=>e.id===c.elementId).hidden,true);
for(const p of data.pages){
  for(const e of p.elements){
    assert.ok(!/nyan[\s-]*gear/i.test(e.text));
    if(e.type==='Text')assert.ok(e.text.length<=simplification.maxDefaultTextCharacters,`${p.name}: long default copy`);
    assert.ok(!(e.type==='TextField'&&/^Type (DELETE|OVERWRITE|REVOKE|\\\(action)/.test(e.text)));
  }
  if(p.confirmation){
    const toggle=byId.get(p.id).elements.find(e=>e.id===p.confirmation.toggleId);
    assert.equal(toggle.type,'Toggle');assert.equal(toggle.value,0);
    assert.ok(p.confirmation.actionIds.every(id=>p.elements.some(e=>e.id===id)));
  }
}
let scripts=0;
for(const html of [board,atlas,messaging,await text('screenshots\\iphone-duo-examples.html')]){
  for(const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)){
    if(/application\/json/.test(match[1]))continue;
    new Script(match[2]);scripts++;
  }
}
const files=async dir=>{
  const entries=await readdir(dir,{withFileTypes:true});
  const groups=await Promise.all(entries.map(e=>e.isDirectory()?files(join(dir,e.name)):[join(dir,e.name)]));
  return groups.flat();
};
let links=0;
for(const path of (await files(root)).filter(p=>p.endsWith('.md'))){
  const markdown=await readFile(path,'utf8');
  for(const match of markdown.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)){
    const target=match[1].replace(/^<|>$/g,'').split('#')[0];
    if(!target||/^[a-z]+:/i.test(target))continue;
    await access(resolve(dirname(path),decodeURIComponent(target.replaceAll('/','\\'))));
    links++;
  }
}
console.log(`Research validated: 44 apps, 312 references, 202 studies, 2,020 geometry cases, ${scripts} browser scripts, ${links} local documentation links. Messaging proof current: ${messagingProof.behaviorChecks} behavior checks, ${messagingGeometry.cases} layout cases.`);
