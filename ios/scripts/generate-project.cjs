// Deterministic Xcode project: app + WidgetKit extension, no paid capabilities.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const objects = {};
const id = (group, n = 1) => group + n.toString(16).toUpperCase().padStart(24 - group.length, '0');
const put = (key, value) => (objects[key] = value, key);
const quote = value => JSON.stringify(String(value));
function serialize(value) {
  if (Array.isArray(value)) return '(' + value.map(serialize).join(', ') + ')';
  if (value && typeof value === 'object') return '{' + Object.entries(value).map(([k,v]) => quote(k) + ' = ' + serialize(v) + ';').join('\n') + '}';
  return quote(value);
}
const project = id('A5'), app = id('A4'), widget = id('B4');
const appFiles = fs.readdirSync(path.join(root, 'SaldoLeve')).filter(x => x.endsWith('.swift')).sort();
const appRefs = appFiles.map((name, index) => put(id('A2', index + 100), {isa: 'PBXFileReference', lastKnownFileType: 'sourcecode.swift', path: name, sourceTree: '<group>'}));
const appBuilds = appRefs.map((ref, index) => put(id('A1', index + 100), {isa: 'PBXBuildFile', fileRef: ref}));
const resourceNames = [['config.json','text.json'], ['Assets.xcassets','folder.assetcatalog'], ['PrivacyInfo.xcprivacy','text.xml'], ['Settings.bundle','wrapper.cfbundle']];
const resourceRefs = resourceNames.map(([name,type],index) => put(id('A2', index + 10), {isa:'PBXFileReference',lastKnownFileType:type,path:name,sourceTree:'<group>'}));
const resourceBuilds = resourceRefs.map((ref,index) => put(id('A1', index + 10), {isa:'PBXBuildFile',fileRef:ref}));
const info = put(id('A2',20), {isa:'PBXFileReference',lastKnownFileType:'text.plist.xml',path:'Info.plist',sourceTree:'<group>'});
const productApp = put(id('A2',30), {isa:'PBXFileReference',explicitFileType:'wrapper.application',includeInIndex:'0',path:'SaldoLeve.app',sourceTree:'BUILT_PRODUCTS_DIR'});
const productWidget = put(id('B2',30), {isa:'PBXFileReference',explicitFileType:'wrapper.app-extension',includeInIndex:'0',path:'SaldoLeveWidgets.appex',sourceTree:'BUILT_PRODUCTS_DIR'});
const widgetRefs = ['SaldoLeveWidgets.swift','WidgetModels.swift'].map((name,index) => put(id('B2',index+1),{isa:'PBXFileReference',lastKnownFileType:'sourcecode.swift',path:name,sourceTree:'<group>'}));
const widgetBuilds = widgetRefs.map((ref,index) => put(id('B1',index+1),{isa:'PBXBuildFile',fileRef:ref}));
const uiTarget = id('C4');
const uiRef = put(id('C2'),{isa:'PBXFileReference',lastKnownFileType:'sourcecode.swift',path:'InteractionTests.swift',sourceTree:'<group>'});
const uiBuild = put(id('C1'),{isa:'PBXBuildFile',fileRef:uiRef});
const uiProduct = put(id('C2',30),{isa:'PBXFileReference',explicitFileType:'wrapper.cfbundle',includeInIndex:'0',path:'SaldoLeveUITests.xctest',sourceTree:'BUILT_PRODUCTS_DIR'});
put(id('C3'),{isa:'PBXGroup',children:[uiRef],path:'UITests',sourceTree:'<group>'});
const widgetInfo = put(id('B2',20), {isa:'PBXFileReference',lastKnownFileType:'text.plist.xml',path:'Info.plist',sourceTree:'<group>'});
const widgetConfig = put(id('B1',10),{isa:'PBXBuildFile',fileRef:resourceRefs[0]});
put(id('A3'),{isa:'PBXGroup',children:[id('A3',2),id('B3'),id('C3'),id('A3',3)],sourceTree:'<group>'});
put(id('A3',2),{isa:'PBXGroup',children:[...appRefs,...resourceRefs,info],path:'SaldoLeve',sourceTree:'<group>'});
put(id('B3'),{isa:'PBXGroup',children:[...widgetRefs,widgetInfo],path:'SaldoLeveWidgets',sourceTree:'<group>'});
put(id('A3',3),{isa:'PBXGroup',children:[productApp,productWidget,uiProduct],name:'Products',sourceTree:'<group>'});
function phase(key,isa,files) { return put(key,{isa,buildActionMask:'2147483647',files,runOnlyForDeploymentPostprocessing:'0'}); }
const appSources = phase(id('A6'),'PBXSourcesBuildPhase',appBuilds);
const appFrameworks = phase(id('A6',2),'PBXFrameworksBuildPhase',[]);
const appResources = phase(id('A6',3),'PBXResourcesBuildPhase',resourceBuilds);
const embed = put(id('B1',40),{isa:'PBXBuildFile',fileRef:productWidget,settings:{ATTRIBUTES:['RemoveHeadersOnCopy']}});
const copy = put(id('A6',4),{isa:'PBXCopyFilesBuildPhase',buildActionMask:'2147483647',dstPath:'',dstSubfolderSpec:'13',files:[embed],name:'Embed App Extensions',runOnlyForDeploymentPostprocessing:'0'});
const widgetSources = phase(id('B6'),'PBXSourcesBuildPhase',widgetBuilds);
const widgetFrameworks = phase(id('B6',2),'PBXFrameworksBuildPhase',[]);
const widgetResources = phase(id('B6',3),'PBXResourcesBuildPhase',[widgetConfig]);
const proxy = put(id('B9'),{isa:'PBXContainerItemProxy',containerPortal:project,proxyType:'1',remoteGlobalIDString:widget,remoteInfo:'SaldoLeveWidgets'});
const dependency = put(id('B9',2),{isa:'PBXTargetDependency',target:widget,targetProxy:proxy});
const uiProxy = put(id('C9'),{isa:'PBXContainerItemProxy',containerPortal:project,proxyType:'1',remoteGlobalIDString:app,remoteInfo:'SaldoLeve'});
const uiDependency = put(id('C9',2),{isa:'PBXTargetDependency',target:app,targetProxy:uiProxy});
put(uiTarget,{isa:'PBXNativeTarget',buildConfigurationList:id('C8'),buildPhases:[phase(id('C6'),'PBXSourcesBuildPhase',[uiBuild]),phase(id('C6',2),'PBXFrameworksBuildPhase',[])],buildRules:[],dependencies:[uiDependency],name:'SaldoLeveUITests',productName:'SaldoLeveUITests',productReference:uiProduct,productType:'com.apple.product-type.bundle.ui-testing'});
put(app,{isa:'PBXNativeTarget',buildConfigurationList:id('A8',2),buildPhases:[appSources,appFrameworks,appResources,copy],buildRules:[],dependencies:[dependency],name:'SaldoLeve',productName:'SaldoLeve',productReference:productApp,productType:'com.apple.product-type.application'});
put(widget,{isa:'PBXNativeTarget',buildConfigurationList:id('B8'),buildPhases:[widgetSources,widgetFrameworks,widgetResources],buildRules:[],dependencies:[],name:'SaldoLeveWidgets',productName:'SaldoLeveWidgets',productReference:productWidget,productType:'com.apple.product-type.app-extension'});
put(project,{isa:'PBXProject',attributes:{BuildIndependentTargetsInParallel:'YES',LastUpgradeCheck:'1600',TargetAttributes:{[app]:{CreatedOnToolsVersion:'16.0'},[widget]:{CreatedOnToolsVersion:'16.0'},[uiTarget]:{CreatedOnToolsVersion:'16.0',TestTargetID:app}}},buildConfigurationList:id('A8'),compatibilityVersion:'Xcode 14.0',developmentRegion:'pt_BR',hasScannedForEncodings:'0',knownRegions:['pt_BR','en','Base'],mainGroup:id('A3'),productRefGroup:id('A3',3),projectDirPath:'',projectRoot:'',targets:[app,widget,uiTarget]});
const base = {CLANG_ENABLE_MODULES:'YES',CLANG_ENABLE_OBJC_ARC:'YES',IPHONEOS_DEPLOYMENT_TARGET:'16.4',SDKROOT:'iphoneos',SWIFT_VERSION:'5.0'};
const target = {CODE_SIGN_STYLE:'Automatic',CURRENT_PROJECT_VERSION:'1',GENERATE_INFOPLIST_FILE:'NO',MARKETING_VERSION:'2.7.0',PRODUCT_NAME:'$(TARGET_NAME)',SUPPORTED_PLATFORMS:'iphoneos iphonesimulator',SUPPORTS_MACCATALYST:'NO',SWIFT_EMIT_LOC_STRINGS:'YES',SWIFT_VERSION:'5.0',TARGETED_DEVICE_FAMILY:'1'};
for (const [index,name] of ['Debug','Release'].entries()) {
  put(id('A7',index+1),{isa:'XCBuildConfiguration',buildSettings:{...base,DEBUG_INFORMATION_FORMAT:name==='Debug'?'dwarf':'dwarf-with-dsym',...(name==='Debug'?{ENABLE_TESTABILITY:'YES',GCC_PREPROCESSOR_DEFINITIONS:['DEBUG=1','$(inherited)'],SWIFT_ACTIVE_COMPILATION_CONDITIONS:'DEBUG',SWIFT_OPTIMIZATION_LEVEL:'-Onone'}:{SWIFT_COMPILATION_MODE:'wholemodule',SWIFT_OPTIMIZATION_LEVEL:'-O',VALIDATE_PRODUCT:'YES'})},name});
  put(id('A7',index+3),{isa:'XCBuildConfiguration',buildSettings:{...target,ASSETCATALOG_COMPILER_APPICON_NAME:'AppIcon',INFOPLIST_FILE:'SaldoLeve/Info.plist',PRODUCT_BUNDLE_IDENTIFIER:'br.com.ilucascesar.saldoleve',LD_RUNPATH_SEARCH_PATHS:['$(inherited)','@executable_path/Frameworks']},name});
  put(id('B7',index+1),{isa:'XCBuildConfiguration',buildSettings:{...target,APPLICATION_EXTENSION_API_ONLY:'YES',IPHONEOS_DEPLOYMENT_TARGET:'17.0',INFOPLIST_FILE:'SaldoLeveWidgets/Info.plist',PRODUCT_BUNDLE_IDENTIFIER:'br.com.ilucascesar.saldoleve.widgets',SKIP_INSTALL:'YES',LD_RUNPATH_SEARCH_PATHS:['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']},name});
  put(id('C7',index+1),{isa:'XCBuildConfiguration',buildSettings:{...target,GENERATE_INFOPLIST_FILE:'YES',PRODUCT_BUNDLE_IDENTIFIER:'br.com.ilucascesar.saldoleve.uitests',TEST_TARGET_NAME:'SaldoLeve',SKIP_INSTALL:'YES',SWIFT_EMIT_LOC_STRINGS:'NO',LD_RUNPATH_SEARCH_PATHS:['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks']},name});
}
for (const [key,configs] of [[id('A8'),[id('A7'),id('A7',2)]],[id('A8',2),[id('A7',3),id('A7',4)]],[id('B8'),[id('B7'),id('B7',2)]],[id('C8'),[id('C7'),id('C7',2)]]]) put(key,{isa:'XCConfigurationList',buildConfigurations:configs,defaultConfigurationIsVisible:'0',defaultConfigurationName:'Release'});
fs.writeFileSync(path.join(root,'SaldoLeve.xcodeproj','project.pbxproj'),'// !$*UTF8*$!\n' + serialize({archiveVersion:'1',classes:{},objectVersion:'56',objects,rootObject:project}) + '\n');
console.log(`Projeto gerado: ${appFiles.length} fontes do app + 2 fontes WidgetKit, sem App Groups.`);
