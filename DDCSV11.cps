/* 
Modified version of Jay McClennan's post-processor for the DDCSV1.1
with bits of OpenbuildsGRBL.cps mixed in.

Copyright 2017 Jay McClellan

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

 */

description = "DDCSV1.1 and CNC Shark";
vendor = "BrainRight.com";
vendorUrl = "http://www.BrainRight.com";

certificationLevel = 2;
minimumRevision = 24000;

extension = "tap";
setCodePage("ascii");
tolerance_mm = 0.002
tolerance = spatial(tolerance_mm, MM);

capabilities = CAPABILITY_MILLING | CAPABILITY_JET; // Adding Jet 		


minimumChordLength = spatial(0.1, MM);
minimumCircularRadius = spatial(0.1, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = false;
allowSpiralMoves = false;
allowedCircularPlanes = (1 << PLANE_XY); // allow only X-Y circular motion

properties = {
  spindleOnOffDelay: 1.0,
  hasCoolant: false,
  hasLubrication: false,
  machineSafeZHeightMM: 5.0,
}

propertyDefinitions = {
  spindleOnOffDelay: {
    title: "Spindle On/Off Delay (s)",
    description: "Time for the spindle to start or stop",
    type: "number",
  },
  hasCoolant: {
    title: "Has Coolant",
    description: "If the machine has a coolant system (M8/M9)",
    type: "boolean",
  },
  hasLubrication: {
    title: "Has Lubrication",
    description: "If the machine has a lubrication system (M10/M11)",
    type: "boolean",
  },
  machineSafeZHeightMM: {
    title: "Safe Z Height",
    description: "A Safe height in millimeters to retract the spindle prior to operation",
    type: "number",
  },
}
var xyzFormat = createFormat({decimals:(3), forceDecimal:true, trim:false});
var feedFormat = createFormat({decimals:(unit == MM ? 0 : 1), forceDecimal:false});
var taperFormat = createFormat({decimals:1, scale:DEG});

var xOutput = createVariable({prefix:"X", force:true}, xyzFormat);
var yOutput = createVariable({prefix:"Y", force:true}, xyzFormat);
var zOutput = createVariable({prefix:"Z", force:true}, xyzFormat);
var aOutput = createVariable({prefix:"A", force:true}, xyzFormat);

var iOutput = createReferenceVariable({prefix:"I", force:true}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J", force:true}, xyzFormat);
var feedOutput = createVariable({prefix:"F"}, feedFormat);

var safeRetractZ = 0; // safe Z coordinate for retraction
var showSectionTools = false; // true to show the tool name in each section

// Formats a bounding box as a readable string 
function formatBoundingBox(box) {
  return xyzFormat.format(box.lower.x) + " <= X <= " + xyzFormat.format(box.upper.x) + " | " +
    xyzFormat.format(box.lower.y) + " <= Y <= " + xyzFormat.format(box.upper.y) + " | " +
    xyzFormat.format(box.lower.z) + " <= Z <= " + xyzFormat.format(box.upper.z);
}

// Formats a tool description as a readable string. This is also used to compare tools
// when warning about multiple tool types, so it will ignore minor tool differences if the
// main parameters are the same.
function formatTool(tool) {
  var str = "Tool: " + getToolTypeName(tool.type);
  str += ", D=" + xyzFormat.format(tool.diameter) + " " +
    localize("CR") + "=" + xyzFormat.format(tool.cornerRadius);
  if ((tool.taperAngle > 0) && (tool.taperAngle < Math.PI)) {
    str += " " + localize("TAPER") + "=" + taperFormat.format(tool.taperAngle) + localize("deg");
  }
  
  return str;
}

function mmToInch(val) {
  return (1.0 * val)/25.4
}
function inchToMM(val) {
  return (1.0 * val) * 25.4
}
function onOpen() {
  if (programName) {
    writeComment("Program: " + programName);
  }
  if (programComment) {
    writeComment(programComment);
  }
 
  var globalBounds; // Overall bounding box of tool travel throughout all sections
  var toolsUsed = []; // Tools used (hopefully just one) in the order they are used 
  var toolpathNames = []; // Names of toolpaths, i.e. sections
  
  var numberOfSections = getNumberOfSections(); 
  for (var i = 0; i < numberOfSections; ++i) {
    var section = getSection(i);
    var boundingBox = section.getGlobalBoundingBox();
    if (globalBounds)
      globalBounds.expandToBox(boundingBox);
    else
      globalBounds = boundingBox;

    toolpathNames.push(section.getParameter("operation-comment"));
    
    if (section.hasParameter('operation:clearanceHeight_value')) {
      safeRetractZ = Math.max(safeRetractZ, section.getParameter('operation:clearanceHeight_value'));
      if (section.getUnit() == MM && unit == IN) {
        safeRetractZ = mmToInch(safeRetractZ);
      }
      else if (section.getUnit() == IN && unit == MM) {
        safeRetractZ = inchToMM(safeRetractZ);
      }       
    }
   
    // This builds up the list of tools used in the order they are encountered, whereas getToolTable() returns an unordered list
    var tool = section.getTool();
    var desc = formatTool(tool);
    if (toolsUsed.indexOf(desc) == -1)
      toolsUsed.push(desc);
  }

  // Normal practice is to run one post with all paths having exactly the same tool, but in some cases differently-defined tools
  // may actually be the same physical tool but with different nominal feeds etc. This warning is only shown when the formatted tool
  // descriptions differ.
  if (toolsUsed.length > 1) {
     var answer = promptKey2("WARNING: Multiple tools are used, but tool changes are not supported.",
       toolsUsed.join("\r\n") + "\r\n\r\nContinue anyway?", "YN");
     if (answer != "Y")
       error("Tool changes are not supported");
     
     showSectionTools = true; // show the tool type used in each section.
  }

  writeComment((numberOfSections > 1 ? "Toolpaths: " : "Toolpath: ") + toolpathNames.join(", "));
  
  switch (unit) {
  case IN:
    writeComment("Units: inches");
    break;
  case MM:
    writeComment("Units: millimeters");
    break;
  default:
    error("Unsupported units: " + unit);
    return;
  }
   
  for (var i=0; i<toolsUsed.length; ++i) {
    writeComment(toolsUsed[i]);
  }
  
  writeComment("Workpiece:   " + formatBoundingBox(getWorkpiece()));
  writeComment("Tool travel: " + formatBoundingBox(globalBounds));
  writeComment("Safe Z: " + xyzFormat.format(safeRetractZ));

  writeln("G90"); // absolute coordinates
  
  switch (unit) {
  case IN:
    writeln("G20"); // inches
    writeln("G64 P" + mmToInch(tolerance_mm)); // precision in inches
    break;
  case MM:
    writeln("G21"); // millimeters
    writeln("G64 P" + tolerance_mm); // precision in mm
    break;
  }
  
  writeln("G00 " + zOutput.format(safeRetractZ)); // retract to safe Z

  onImpliedCommand(COMMAND_START_SPINDLE);
  writeln("S " + getSection(0).getTool().spindleRPM); // initial spindle speed
  writeln("M03"); // start spindle
}

function writeComment(text) {
  text = text.replace(/\(/g," ").replace(/\)/g," ");
  writeln("(" + text + ")");
}

function onComment(message) {
  var comments = String(message).split(";");
  for (comment in comments) {
    writeComment(comments[comment]);
  }
}

function onSection() {
  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeComment("--- " + comment + " ---");
    }
  }
  
  // We only show the tool in each section if there are multiple tools
  if (showSectionTools) {
    writeComment(formatTool(currentSection.getTool()));
  }
  
  writeln("S " + currentSection.getTool().spindleRPM); // spindle speed
}

function onRapid(_x, _y, _z) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  if (x || y || z) {
    writeln("G00 " + x + " " + y + " " + z);
  }
}

function onLinear(_x, _y, _z, feed) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = feedOutput.format(feed);
  if (x || y || z) {
    writeln("G01 " + x + " " + y + " " + z + " " + f);
  }
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  var start = getCurrentPosition();
  
  var f = feedOutput.format(feed);
  if (f) {
    writeln(f);
  }
  
  writeln((clockwise ? "G02 " : "G03 ") + 
    xOutput.format(x) + " " +
    yOutput.format(y) + " " +
    zOutput.format(z) + " " +
    iOutput.format(cx - start.x, 0) + " " +
    jOutput.format(cy - start.y, 0));
}

function onOrientateSpindle(_a) {
  var a = xOutput.format(_a);
  if (a) {
    writeln("G01 " + a);
  }
}

function onClose() {
  writeln("G00 " + zOutput.format(safeRetractZ)); // retract to safe Z
  onImpliedCommand(COMMAND_STOP_SPINDLE);
  writeln("M5");
  onImpliedCommand(COMMAND_END);
  writeln("M2");
}
