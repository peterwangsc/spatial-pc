#!/usr/bin/env python3
"""Small deterministic Xcode generator; requires only Python's standard library."""
from pathlib import Path
import hashlib,json,os
root=Path(__file__).resolve().parents[1]
objects={}
def uid(s):return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def put(key,isa,**kw):
 k=uid(key);objects[k]={'isa':isa,**kw};return k
def quote(s):return json.dumps(str(s))
def render(v):
 if isinstance(v,dict):return '{ '+ ' '.join(quote(k)+' = '+render(x)+';' for k,x in v.items())+' }'
 if isinstance(v,list):return '( '+', '.join(render(x) for x in v)+' )'
 return quote(v)
files=[];builds=[]
for path in sorted((root/'visionos/SpatialPC').rglob('*')):
 if path.suffix not in ['.swift','.metal']:continue
 rel=path.relative_to(root/'visionos').as_posix()
 ref=put(rel,'PBXFileReference',lastKnownFileType='sourcecode.swift' if path.suffix=='.swift' else 'sourcecode.metal',path=rel,sourceTree='<group>')
 files.append(ref);builds.append(put('build:'+rel,'PBXBuildFile',fileRef=ref))
product=put('product','PBXFileReference',explicitFileType='wrapper.application',path='SpatialPC.app',sourceTree='BUILT_PRODUCTS_DIR')
products=put('products','PBXGroup',children=[product],name='Products',sourceTree='<group>')
group=put('mainGroup','PBXGroup',children=files+[products],sourceTree='<group>')
sources=put('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0)
frameworks=put('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
configs=[]
for config in ['Debug','Release']:
 settings={'ALWAYS_SEARCH_USER_PATHS':'NO','PRODUCT_NAME':'SpatialPC','PRODUCT_BUNDLE_IDENTIFIER':os.environ.get('SPATIAL_PC_BUNDLE_ID','com.example.spatialpc'),'DEVELOPMENT_TEAM':os.environ.get('SPATIAL_PC_TEAM',''),'CODE_SIGN_STYLE':'Automatic','SDKROOT':'xros','SUPPORTED_PLATFORMS':'xros xrsimulator','TARGETED_DEVICE_FAMILY':'7','XROS_DEPLOYMENT_TARGET':'2.0','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'complete','INFOPLIST_FILE':'SpatialPC/Info.plist','GENERATE_INFOPLIST_FILE':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'YES','MARKETING_VERSION':'0.1.0','CURRENT_PROJECT_VERSION':'1','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym','MTL_ENABLE_DEBUG_INFO':'INCLUDE_SOURCE' if config=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if config=='Debug' else ''}
 configs.append(put('config:'+config,'XCBuildConfiguration',buildSettings=settings,name=config))
configlist=put('configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
target=put('target','PBXNativeTarget',buildConfigurationList=configlist,buildPhases=[sources,frameworks],buildRules=[],dependencies=[],name='SpatialPC',productName='SpatialPC',productReference=product,productType='com.apple.product-type.application')
project=put('project','PBXProject',attributes={'LastUpgradeCheck':'2650'},buildConfigurationList=configlist,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[target])
p=root/'visionos/SpatialPC.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2650" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SpatialPC.app" BlueprintName="SpatialPC" ReferencedContainer="container:SpatialPC.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SpatialPC.app" BlueprintName="SpatialPC" ReferencedContainer="container:SpatialPC.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
(p/'xcshareddata/xcschemes/SpatialPC.xcscheme').write_text(scheme)
