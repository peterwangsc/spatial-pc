#!/usr/bin/env swift
// Original vector artwork, rasterized into Apple's three-layer visionOS icon.
// Run from the repository root: swift scripts/generate_icon.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let size = 1024
let assets = URL(fileURLWithPath:"visionos/SpatialPC/Assets.xcassets/AppIcon.solidimagestack")
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat = 1) -> CGColor { CGColor(red:r,green:g,blue:b,alpha:a) }
func rounded(_ rect:CGRect,_ radius:CGFloat) -> CGPath { CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil) }
func gradient(_ context:CGContext,_ rect:CGRect,_ colors:[CGColor]) {
    let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors as CFArray,locations:[0,1])!
    context.drawLinearGradient(gradient,start:CGPoint(x:rect.minX,y:rect.minY),end:CGPoint(x:rect.maxX,y:rect.maxY),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
}
func draw(_ layer:String,_ c:CGContext) {
    if layer == "Back" {
        gradient(c,CGRect(x:0,y:0,width:size,height:size),[color(0.025,0.07,0.16),color(0.075,0.19,0.28)])
    } else if layer == "Middle" {
        let panel = CGRect(x:206,y:414,width:508,height:326)
        c.setShadow(offset:CGSize(width:0,height:-18),blur:36,color:color(0,0,0,0.3))
        c.addPath(rounded(panel,34));c.setFillColor(color(0.32,0.91,0.82));c.fillPath()
        c.setShadow(offset:.zero,blur:0,color:nil)
        c.addPath(rounded(panel.insetBy(dx:15,dy:15),22));c.setFillColor(color(0.08,0.27,0.33));c.fillPath()
    } else {
        let panel = CGRect(x:318,y:276,width:506,height:324)
        c.setShadow(offset:CGSize(width:0,height:-18),blur:38,color:color(0,0,0,0.4))
        c.addPath(rounded(panel,34));c.setFillColor(color(0.87,1,0.98));c.fillPath()
        c.setShadow(offset:.zero,blur:0,color:nil)
        c.saveGState();c.addPath(rounded(panel.insetBy(dx:15,dy:15),22));c.clip()
        gradient(c,panel,[color(0.1,0.52,0.71),color(0.32,0.91,0.82)]);c.restoreGState()
        c.setFillColor(color(0.87,1,0.98,0.95));c.addPath(rounded(CGRect(x:518,y:241,width:104,height:10),5));c.fillPath()
    }
}
func bitmap() -> CGContext { CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)! }
func png(_ c:CGContext,_ path:URL) throws {
    let out = CGImageDestinationCreateWithURL(path as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(out,c.makeImage()!,nil);guard CGImageDestinationFinalize(out) else { throw NSError(domain:"Icon",code:1) }
}
func json(_ value:Any,_ path:URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:path) }
let info:[String:Any] = ["author":"xcode","version":1]
try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
try json(["info":info],assets.deletingLastPathComponent().appendingPathComponent("Contents.json"))
try json(["info":info,"layers":["Front","Middle","Back"].map { ["filename":$0+".solidimagestacklayer"] }],assets.appendingPathComponent("Contents.json"))
let composite = bitmap()
for layer in ["Back","Middle","Front"] {
    let folder = assets.appendingPathComponent(layer+".solidimagestacklayer")
    let content = folder.appendingPathComponent("Content.imageset")
    try FileManager.default.createDirectory(at:content,withIntermediateDirectories:true)
    try json(["info":info],folder.appendingPathComponent("Contents.json"))
    try json(["info":info,"images":[["idiom":"vision","scale":"2x","filename":layer+".png"]]],content.appendingPathComponent("Contents.json"))
    let c = bitmap();draw(layer,c);try png(c,content.appendingPathComponent(layer+".png"));draw(layer,composite)
}
try png(composite,URL(fileURLWithPath:"design/app-icon.png"))
