const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('static/scanner.js','utf8');
const TOKEN = 'NLP-20261027-0123456789ABCDEF';

function setup(options={}) {
  function element() {
    return {handlers:{},hidden:false,disabled:false,textContent:'',value:'',files:[],
      addEventListener(name,fn){this.handlers[name]=fn;},focus(){this.focused=true;},
      async play(){}};
  }
  const ids=Object.fromEntries(['scan-button','scanner-video','scanner-status','qr-photo','pass_token'].map(id=>[id,element()]));
  const events={}; const docEvents={}; let stops=0, closes=0, reads=0;
  const stream={getTracks:()=>[{stop(){stops++;}}]};
  const detector=class {
    static async getSupportedFormats(){return ['qr_code'];}
    async detect(){reads++;return options.codes ?? [{rawValue:TOKEN}];}
  };
  const window={addEventListener:(name,fn)=>events[name]=fn,setTimeout:()=>{},BarcodeDetector:detector};
  const document={hidden:false,getElementById:id=>ids[id],addEventListener:(name,fn)=>docEvents[name]=fn};
  const context={window,document,BarcodeDetector:detector,
    navigator:{mediaDevices:{getUserMedia:options.camera || (async()=>stream)}},
    createImageBitmap:async()=>({width:200,height:200,close(){closes++;}})};
  if(options.unsupported)delete window.BarcodeDetector;
  vm.runInNewContext(source,context);
  return {ids,events,docEvents,document,stream,get stops(){return stops;},get closes(){return closes;},get reads(){return reads;}};
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));

test('camera captures token for review and stops tracks without submitting a return',async()=>{
  const s=setup();await s.ids['scan-button'].handlers.click();await flush();
  assert.equal(s.ids.pass_token.value,TOKEN);
  assert.equal(s.stops,1);
  assert.equal(s.ids['scanner-video'].hidden,true);
  assert.match(s.ids['scanner-status'].textContent,/Review it/);
});
test('non-library QR does not populate token',async()=>{
  const s=setup({codes:[{rawValue:'https://attacker.example'}]});
  await s.ids['scan-button'].handlers.click();await flush();
  assert.equal(s.ids.pass_token.value,'');
  assert.match(s.ids['scanner-status'].textContent,/not a recognized/);
  s.events.pagehide();assert.equal(s.stops,1);
});
test('unsupported browser explains paste and USB fallback',async()=>{
  const s=setup({unsupported:true});await s.ids['scan-button'].handlers.click();
  assert.match(s.ids['scanner-status'].textContent,/USB QR scanner/);
  assert.equal(s.reads,0);
});
test('camera rejection clears starting state',async()=>{
  const s=setup({camera:async()=>{throw new Error('denied');}});
  await s.ids['scan-button'].handlers.click();
  assert.equal(s.ids['scan-button'].disabled,false);
  assert.match(s.ids['scanner-status'].textContent,/unavailable/);
});
test('camera resolved after leaving page is stopped immediately',async()=>{
  let resolveCamera;
  const pending=new Promise(resolve=>resolveCamera=resolve);
  const s=setup({camera:()=>pending});
  const start=s.ids['scan-button'].handlers.click();await flush();
  s.events.pagehide();resolveCamera(s.stream);await start;
  assert.equal(s.stops,1);assert.equal(s.reads,0);
});
test('selected photo is decoded locally and releases bitmap memory',async()=>{
  const s=setup();s.ids['qr-photo'].files=[{type:'image/png',size:100}];
  await s.ids['qr-photo'].handlers.change();
  assert.equal(s.ids.pass_token.value,TOKEN);assert.equal(s.closes,1);
});
test('oversized photo is rejected before decoding',async()=>{
  const s=setup();s.ids['qr-photo'].files=[{type:'image/png',size:9*1024*1024}];
  await s.ids['qr-photo'].handlers.change();
  assert.equal(s.reads,0);assert.match(s.ids['scanner-status'].textContent,/8 MB/);
});
test('backgrounding the tab stops the camera',async()=>{
  const s=setup({codes:[]});await s.ids['scan-button'].handlers.click();await flush();
  s.document.hidden=true;s.docEvents.visibilitychange();
  assert.equal(s.stops,1);assert.equal(s.ids['scanner-video'].hidden,true);
});
