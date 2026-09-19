import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Presentation, PresentationFile } from "@oai/artifact-tool";

const workspaceDir = "C:\\Users\\admir\\Desktop\\Teknuvation\\SSC-System";
const SKILL_DIR = "C:\\Users\\admir\\.codex\\plugins\\cache\\openai-primary-runtime\\presentations\\26.905.11957\\skills\\presentations";
const TMP_DIR = path.join(workspaceDir, ".codex-ppt-build");
const FINAL_PPTX = path.join(workspaceDir, "presentation-output", "SSC-Portal-Stakeholder-Presentation-v7.pptx");
const RUNTIME_PYTHON = "C:\\Users\\admir\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\python\\python.exe";
const { resolvePresentationFont, finalizePresentation } = await import(
  pathToFileURL(path.join(SKILL_DIR, "container_tools", "artifact_tool_utils.mjs")).href,
);

const FONT = resolvePresentationFont({ fontFamily: "Segoe UI" });
const W = 1280;
const H = 720;
const C = {
  red: "#FF2327",
  redDark: "#C91217",
  paleRed: "#FFF0F0",
  ink: "#15171C",
  body: "#3F4652",
  muted: "#6B7280",
  line: "#D9DDE3",
  soft: "#F5F6F8",
  white: "#FFFFFF",
  green: "#138A52",
  amber: "#B66A00",
};

const screenshots = [
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-3f862e66-5d06-4e38-83bf-fc4ef7752255.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-a169e3dd-b75f-4593-aee5-a572f1cee5f4.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-1224df23-288a-4bb5-b805-b8a6fa326532.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-d2196330-e3a7-47a5-882f-a3f7a4c699f7.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-81f8191c-581d-49e5-9e5e-f496404f7d65.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-87b678a3-7b60-4cb0-a77a-e8b7735abd5d.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-42b24f90-7b9c-437a-a615-2f66a6ec7b66.png",
  "C:\\Users\\admir\\AppData\\Local\\Temp\\codex-clipboard-25673b11-81ba-4c6d-801b-a340746c331b.png",
];
const imageBytes = await Promise.all(screenshots.map((file) => fs.readFile(file)));

const presentation = Presentation.create({ slideSize: { width: W, height: H } });

function rect(slide, left, top, width, height, fill, options = {}) {
  return slide.shapes.add({
    geometry: options.geometry ?? "rect",
    position: { left, top, width, height },
    fill,
    line: options.line ?? { fill: "none", width: 0 },
    borderRadius: options.borderRadius,
    shadow: options.shadow,
  });
}

function text(slide, value, left, top, width, height, options = {}) {
  const shape = slide.shapes.add({
    geometry: "textbox",
    position: { left, top, width, height },
    fill: options.fill ?? "none",
    line: options.line ?? { fill: "none", width: 0 },
    borderRadius: options.borderRadius,
  });
  shape.text = value;
  shape.text.style = {
    typeface: FONT,
    fontSize: options.fontSize ?? 24,
    bold: options.bold ?? false,
    color: options.color ?? C.ink,
    alignment: options.alignment ?? "left",
    verticalAlignment: options.verticalAlignment ?? "top",
    autoFit: options.autoFit ?? "shrinkText",
    wrap: "square",
    insets: options.insets ?? { left: 0, right: 0, top: 0, bottom: 0 },
    lineSpacing: options.lineSpacing,
  };
  return shape;
}

function image(slide, index, left, top, width, height, options = {}) {
  return slide.images.add({
    blob: imageBytes[index],
    contentType: "image/png",
    alt: options.alt ?? `SSC Portal screenshot ${index + 1}`,
    fit: options.fit ?? "cover",
    crop: options.crop,
    geometry: options.geometry ?? "roundRect",
    borderRadius: options.borderRadius ?? 18,
    position: { left, top, width, height },
  });
}

function addTopRule(slide) {
  rect(slide, 0, 0, W, 8, C.red);
}

function addTitle(slide, titleValue, subtitle = null) {
  addTopRule(slide);
  text(slide, titleValue, 66, 38, 1138, 58, {
    fontSize: 46,
    bold: true,
    color: C.ink,
    autoFit: "none",
  });
  if (subtitle) {
    text(slide, subtitle, 68, 100, 1120, 34, {
      fontSize: 22,
      color: C.muted,
      autoFit: "none",
    });
  }
}

function addSlideNumber(slide, number) {
  text(slide, String(number).padStart(2, "0"), 1190, 676, 42, 24, {
    fontSize: 16,
    bold: true,
    color: C.muted,
    alignment: "right",
    autoFit: "none",
  });
}

function addNotes(slide, { speaker, time, visual, say, transition, evidence }) {
  slide.speakerNotes.textFrame.setText(
    `Speaker: ${speaker}\nApproximate speaking time: ${time}\n\nRecommended visual: ${visual}\n\nWhat to say:\n${say}\n\nSuggested transition:\n${transition}\n\nEvidence: ${evidence}`,
  );
  slide.speakerNotes.setVisible(true);
}

// 1. Cover
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  rect(slide, 0, 0, 620, H, C.ink);
  rect(slide, 0, 0, 14, H, C.red);
  rect(slide, 620, 0, 660, H, C.soft);
  rect(slide, 657, 131, 586, 328, C.white, {
    geometry: "roundRect",
    line: { fill: C.line, width: 1 },
    borderRadius: 18,
  });
  image(slide, 0, 670, 144, 560, 302, {
    fit: "contain",
    borderRadius: 10,
    alt: "SSC Portal landing page with the Cor Jesu College campus building",
  });
  rect(slide, 706, 514, 42, 5, C.red);
  text(slide, "One shared workflow for student activities", 706, 539, 480, 62, {
    fontSize: 24,
    bold: true,
    color: C.ink,
    autoFit: "none",
  });
  text(slide, "For students, faculty moderators, and administrators", 706, 612, 490, 28, {
    fontSize: 17,
    color: C.muted,
    autoFit: "none",
  });
  text(slide, "SSC PORTAL", 70, 76, 460, 32, {
    fontSize: 20,
    bold: true,
    color: C.red,
    autoFit: "none",
  });
  text(slide, "A clearer path\nfrom proposal\nto approval", 68, 158, 500, 240, {
    fontSize: 58,
    bold: true,
    color: C.white,
    autoFit: "none",
    lineSpacing: 0.9,
  });
  text(slide, "Stakeholder presentation", 70, 470, 430, 34, {
    fontSize: 24,
    color: "#D4D8DE",
    autoFit: "none",
  });
  text(slide, "Cor Jesu College Student Services Center", 70, 520, 470, 48, {
    fontSize: 20,
    color: "#AEB5BF",
    autoFit: "none",
  });
  addNotes(slide, {
    speaker: "Presenter 1",
    time: "0:30",
    visual: "Landing-page screenshot cropped to emphasize the campus building and portal identity.",
    say: "Good morning. Every campus event begins with an idea, but turning that idea into an approved activity requires coordination between students, moderators, and administrators. Our project, the SSC Portal, gives that coordination one clear path.",
    transition: "Before we show the system, let us begin with the situation that made it necessary.",
    evidence: "User-provided SSC Portal landing-page screenshot; project README.",
  });
}

// 2. Problem
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addTitle(slide, "The work starts before the event", "One proposal carries several kinds of information through several people");
  const labels = [
    ["EVENT DETAILS", "What is happening?"],
    ["REQUIRED FILES", "What must be submitted?"],
    ["REVIEW", "Who needs to act?"],
    ["STATUS", "What happens next?"],
  ];
  const nodes = [];
  for (let i = 0; i < labels.length; i++) {
    const x = 76 + i * 296;
    const node = rect(slide, x, 238, 220, 156, i === 0 ? C.red : C.soft, {
      geometry: "roundRect",
      borderRadius: 18,
      line: { fill: i === 0 ? C.red : C.line, width: 1 },
    });
    nodes.push(node);
    text(slide, labels[i][0], x + 20, 263, 180, 28, {
      fontSize: 17,
      bold: true,
      color: i === 0 ? C.white : C.red,
      autoFit: "none",
    });
    text(slide, labels[i][1], x + 20, 310, 180, 50, {
      fontSize: 25,
      bold: true,
      color: i === 0 ? C.white : C.ink,
      autoFit: "none",
    });
  }
  for (let i = 0; i < nodes.length - 1; i++) {
    slide.shapes.connect(nodes[i], nodes[i + 1], {
      kind: "straight",
      fromSide: "right",
      toSide: "left",
      line: { fill: C.red, width: 3 },
      tail: { type: "arrow", width: "med", length: "med" },
    });
  }
  text(slide, "When these pieces live in separate places, the next step becomes harder to see.", 128, 488, 1024, 60, {
    fontSize: 32,
    bold: true,
    alignment: "center",
    color: C.ink,
    autoFit: "none",
  });
  text(slide, "The risk is delay, missing requirements, and repeated follow-up.", 235, 562, 810, 40, {
    fontSize: 22,
    alignment: "center",
    color: C.muted,
    autoFit: "none",
  });
  addSlideNumber(slide, 2);
  addNotes(slide, {
    speaker: "Presenter 1",
    time: "0:45",
    visual: "Editable four-stage process diagram showing the information that travels with one proposal.",
    say: "The challenge is not simply creating a form. One proposal carries event details, required documents, reviewer responsibilities, and a changing status. When those pieces are tracked separately, students may not know what is missing, reviewers may not know what needs attention, and administrators spend more time following up.",
    transition: "That uncertainty affects each person differently.",
    evidence: "Implemented submission, document, review, and status workflow in the backend and frontend.",
  });
}

// 3. Roles
{
  const slide = presentation.slides.add();
  slide.background.fill = C.soft;
  addTitle(slide, "The same delay affects three roles", "Each person needs a different answer from the same proposal");
  const rows = [
    ["STUDENT", "What do I need to submit, and where does my proposal stand?"],
    ["MODERATOR", "Which documents need my review, and what decision is required?"],
    ["ADMINISTRATOR", "Which record is current, and where is follow-up needed?"],
  ];
  for (let i = 0; i < rows.length; i++) {
    const y = 190 + i * 144;
    text(slide, String(i + 1).padStart(2, "0"), 72, y, 76, 60, {
      fontSize: 46,
      bold: true,
      color: C.red,
      autoFit: "none",
    });
    text(slide, rows[i][0], 175, y + 5, 250, 30, {
      fontSize: 19,
      bold: true,
      color: C.ink,
      autoFit: "none",
    });
    text(slide, rows[i][1], 425, y - 4, 760, 66, {
      fontSize: 29,
      bold: true,
      color: C.body,
      autoFit: "none",
    });
    if (i < rows.length - 1) rect(slide, 175, y + 91, 1010, 2, C.line);
  }
  addSlideNumber(slide, 3);
  addNotes(slide, {
    speaker: "Presenter 1",
    time: "0:50",
    visual: "Three horizontal role statements, with one practical question for each user.",
    say: "A student needs clarity about requirements and status. A moderator needs to see assigned documents and the decision waiting for them. An administrator needs a reliable record of users, organizations, departments, and submissions. The system succeeds only when all three roles can work from the same information.",
    transition: "That shared information became the central idea behind our solution.",
    evidence: "Role model and role-scoped submission access in the backend API.",
  });
}

// 4. Solution introduction
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addTitle(slide, "One shared path through the SSC Portal");
  text(slide, "The portal turns each proposal into a visible journey.", 66, 162, 430, 90, {
    fontSize: 37,
    bold: true,
    color: C.ink,
    autoFit: "none",
  });
  rect(slide, 66, 286, 68, 6, C.red);
  text(slide, "Students see their next action.\nStaff see work waiting for review.\nAdministrators see the whole process.", 66, 324, 445, 150, {
    fontSize: 25,
    color: C.body,
    autoFit: "none",
    lineSpacing: 1.35,
  });
  text(slide, "One account. One current status.", 66, 535, 430, 34, {
    fontSize: 22,
    bold: true,
    color: C.red,
    autoFit: "none",
  });
  image(slide, 1, 555, 148, 660, 435, {
    fit: "cover",
    crop: { left: 0.08, top: 0.04, right: 0.05, bottom: 0.03 },
    alt: "Student dashboard showing submission counts and quick actions",
  });
  addSlideNumber(slide, 4);
  addNotes(slide, {
    speaker: "Presenter 1",
    time: "0:40",
    visual: "Actual student dashboard screenshot beside a short solution statement.",
    say: "Our idea is one shared portal built around the proposal journey. The student dashboard shows submissions, pending reviews, outcomes, and the next action. The same proposal then becomes visible to the people responsible for reviewing and managing it.",
    transition: "To make this concrete, Presenter 2 will follow one proposal through the system.",
    evidence: "User-provided student dashboard screenshot.",
  });
}

// 5. Journey: proposal
{
  const slide = presentation.slides.add();
  slide.background.fill = C.soft;
  addTitle(slide, "Jeferson prepares a General Assembly", "The proposal becomes a complete, readable record before submission");
  image(slide, 2, 632, 138, 545, 516, {
    fit: "contain",
    alt: "Activity proposal preview for a General Assembly",
  });
  const steps = [
    ["01", "Event context", "Category, department, type, date, venue, and expected participants"],
    ["02", "Responsible people", "Applicant and faculty moderator appear in the same record"],
    ["03", "Approval path", "The sign-off block makes the intended review path visible"],
  ];
  for (let i = 0; i < steps.length; i++) {
    const y = 175 + i * 146;
    text(slide, steps[i][0], 72, y, 52, 38, {
      fontSize: 24,
      bold: true,
      color: C.red,
      autoFit: "none",
    });
    text(slide, steps[i][1], 143, y - 2, 390, 36, {
      fontSize: 26,
      bold: true,
      color: C.ink,
      autoFit: "none",
    });
    text(slide, steps[i][2], 143, y + 43, 410, 62, {
      fontSize: 21,
      color: C.body,
      autoFit: "none",
    });
  }
  addSlideNumber(slide, 5);
  addNotes(slide, {
    speaker: "Presenter 2",
    time: "0:55",
    visual: "Actual proposal preview screenshot, with three narrative points beside it.",
    say: "In this example, Jeferson prepares a General Assembly proposal. Before submission, the portal presents the event as one readable record. The event details, responsible people, and intended sign-off path appear together. This lets the student confirm the proposal before it moves forward.",
    transition: "A complete proposal also depends on the right supporting documents.",
    evidence: "User-provided activity proposal preview screenshot; implemented proposal data model.",
  });
}

// 6. Journey: requirements
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addTitle(slide, "Requirements become a guided checklist");
  image(slide, 3, 64, 138, 655, 515, {
    fit: "contain",
    alt: "Required documents upload checklist",
  });
  text(slide, "The student can see", 780, 170, 390, 34, {
    fontSize: 22,
    bold: true,
    color: C.red,
    autoFit: "none",
  });
  const items = [
    ["Required files", "Each document has a clear name and owner."],
    ["Upload rules", "Accepted format and maximum size appear before upload."],
    ["Completion status", "The checklist shows what still needs attention."],
  ];
  for (let i = 0; i < items.length; i++) {
    const y = 235 + i * 125;
    rect(slide, 780, y + 5, 12, 64, C.red);
    text(slide, items[i][0], 818, y, 360, 32, {
      fontSize: 27,
      bold: true,
      color: C.ink,
      autoFit: "none",
    });
    text(slide, items[i][1], 818, y + 44, 360, 50, {
      fontSize: 20,
      color: C.body,
      autoFit: "none",
    });
  }
  addSlideNumber(slide, 6);
  addNotes(slide, {
    speaker: "Presenter 2",
    time: "0:55",
    visual: "Actual required-document checklist screenshot with three highlighted outcomes.",
    say: "Instead of asking students to remember every requirement, the portal turns the checklist into a guided step. Each required file has a name, an assigned reviewer, an accepted format, and a size limit. The student can see what remains before attempting to finalize the proposal.",
    transition: "Once the student submits, the same record becomes visible to staff.",
    evidence: "User-provided required documents screenshot; checklist and document policy implementation.",
  });
}

// 7. Journey: review
{
  const slide = presentation.slides.add();
  slide.background.fill = C.soft;
  addTitle(slide, "The same event reaches the review queue", "Staff can search, filter, and open the proposal from one workspace");
  image(slide, 4, 62, 150, 1156, 467, {
    fit: "cover",
    crop: { left: 0.02, top: 0.01, right: 0.02, bottom: 0.24 },
    alt: "Administrator events and submissions list",
  });
  rect(slide, 865, 548, 305, 58, C.ink, { geometry: "roundRect", borderRadius: 14 });
  text(slide, "Status stays visible", 884, 566, 267, 24, {
    fontSize: 19,
    bold: true,
    color: C.white,
    alignment: "center",
    autoFit: "none",
  });
  addSlideNumber(slide, 7);
  addNotes(slide, {
    speaker: "Presenter 2",
    time: "0:50",
    visual: "Actual Events and Submissions screen, emphasizing visible states and the Review action.",
    say: "Staff do not need a separate copy of the event. The portal places the same proposal in a review queue, where its organization, event type, date, document count, and status remain visible. Draft and pending work can be distinguished immediately, and authorized staff can open the record for review.",
    transition: "That workflow depends on accurate people and organization records behind it.",
    evidence: "User-provided Events and Submissions screenshot; role-scoped submission listing.",
  });
}

// 8. Trusted records
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addTitle(slide, "Trusted records support every proposal", "The current setup carries the approved masterlist and active directory");
  text(slide, "278", 68, 144, 142, 70, { fontSize: 58, bold: true, color: C.red, autoFit: "none" });
  text(slide, "registrar records", 70, 211, 180, 28, { fontSize: 20, color: C.body, autoFit: "none" });
  text(slide, "5", 267, 144, 80, 70, { fontSize: 58, bold: true, color: C.red, autoFit: "none" });
  text(slide, "active organizations", 269, 211, 190, 28, { fontSize: 20, color: C.body, autoFit: "none" });
  text(slide, "6", 484, 144, 80, 70, { fontSize: 58, bold: true, color: C.red, autoFit: "none" });
  text(slide, "departments and offices", 486, 211, 220, 28, { fontSize: 20, color: C.body, autoFit: "none" });
  image(slide, 5, 65, 276, 690, 345, {
    fit: "cover",
    crop: { left: 0, top: 0, right: 0, bottom: 0.07 },
    alt: "Masterlist with 278 registrar records",
  });
  rect(slide, 70, 320, 315, 296, C.soft, { geometry: "roundRect", borderRadius: 12 });
  rect(slide, 94, 410, 8, 86, C.red);
  text(slide, "Personal student details\nhidden for presentation", 122, 422, 235, 64, {
    fontSize: 23,
    bold: true,
    color: C.ink,
    autoFit: "none",
  });
  image(slide, 6, 785, 276, 430, 158, {
    fit: "cover",
    crop: { left: 0.01, top: 0.02, right: 0.01, bottom: 0.40 },
    alt: "Active organizations directory",
  });
  image(slide, 7, 785, 462, 430, 159, {
    fit: "cover",
    crop: { left: 0.01, top: 0.02, right: 0.01, bottom: 0.39 },
    alt: "Departments and offices directory",
  });
  addSlideNumber(slide, 8);
  addNotes(slide, {
    speaker: "Presenter 2",
    time: "0:55",
    visual: "Actual masterlist, organization, and department screens with verified record counts.",
    say: "Every proposal relies on trusted identity and directory data. The current migration carries 278 registrar records, five active organizations, and six departments or offices. Student and faculty IDs accept numeric values without forcing one display format, which protects valid records from inconsistent source formatting. Presenter 3 will now connect this workflow to stakeholder value, readiness, and next steps.",
    transition: "The value appears in the questions each role can now answer.",
    evidence: "Screenshots supplied by the user; migrations V58 through V61; clean database verification.",
  });
}

// 9. Value
{
  const slide = presentation.slides.add();
  slide.background.fill = C.ink;
  rect(slide, 0, 0, W, 8, C.red);
  text(slide, "Value for each stakeholder", 66, 46, 900, 58, {
    fontSize: 46,
    bold: true,
    color: C.white,
    autoFit: "none",
  });
  const values = [
    ["STUDENT", "Knows what to submit and where the proposal stands"],
    ["MODERATOR", "Sees assigned documents and the review waiting for action"],
    ["ADMINISTRATOR", "Works from one current record across the process"],
    ["STAKEHOLDER", "Gains clearer status, accountability, and continuity"],
  ];
  for (let i = 0; i < values.length; i++) {
    const y = 158 + i * 118;
    text(slide, values[i][0], 72, y, 230, 28, {
      fontSize: 18,
      bold: true,
      color: C.red,
      autoFit: "none",
    });
    text(slide, values[i][1], 315, y - 8, 850, 58, {
      fontSize: 29,
      bold: true,
      color: C.white,
      autoFit: "none",
    });
    if (i < values.length - 1) rect(slide, 315, y + 72, 850, 2, "#343945");
  }
  text(slide, "The benefit comes from shared visibility, not from adding another form.", 140, 632, 1000, 38, {
    fontSize: 24,
    color: "#BEC4CE",
    alignment: "center",
    autoFit: "none",
  });
  addNotes(slide, {
    speaker: "Presenter 3",
    time: "0:50",
    visual: "Four role-based outcomes on a dark background, with no feature grid.",
    say: "The portal creates a different benefit for each stakeholder. Students gain clarity. Moderators see the work assigned to them. Administrators work from a current record instead of reconciling separate copies. Stakeholders gain a process whose status and responsibility remain visible from proposal creation through review.",
    transition: "That experience rests on a straightforward technical foundation.",
    evidence: "Implemented role-based screens, document review workflow, status timeline, and administrative records.",
  });
}

// 10. Technology and AI
{
  const slide = presentation.slides.add();
  slide.background.fill = C.white;
  addTitle(slide, "What happens behind the screen", "The technology keeps the experience connected without making decisions for people");

  const browser = rect(slide, 72, 214, 230, 154, C.paleRed, {
    geometry: "roundRect", borderRadius: 18, line: { fill: "#FFC4C5", width: 1 },
  });
  text(slide, "WEB PORTAL", 96, 242, 180, 26, { fontSize: 17, bold: true, color: C.red, autoFit: "none" });
  text(slide, "Students and staff\nuse one portal", 96, 286, 180, 62, { fontSize: 20, bold: true, autoFit: "none" });

  const services = rect(slide, 442, 184, 330, 214, C.ink, {
    geometry: "roundRect", borderRadius: 18,
  });
  text(slide, "APPLICATION SERVICES", 474, 216, 265, 26, { fontSize: 17, bold: true, color: C.red, autoFit: "none" });
  text(slide, "Applies access rules,\nchecks requirements,\nand moves the workflow", 474, 266, 260, 100, {
    fontSize: 26, bold: true, color: C.white, autoFit: "none",
  });

  const data = rect(slide, 914, 162, 270, 126, C.soft, {
    geometry: "roundRect", borderRadius: 18, line: { fill: C.line, width: 1 },
  });
  text(slide, "DATABASE", 940, 187, 210, 24, { fontSize: 17, bold: true, color: C.red, autoFit: "none" });
  text(slide, "Stores records\nand status history", 940, 224, 210, 55, { fontSize: 23, bold: true, autoFit: "none" });

  const files = rect(slide, 914, 330, 270, 126, C.soft, {
    geometry: "roundRect", borderRadius: 18, line: { fill: C.line, width: 1 },
  });
  text(slide, "FILE STORAGE", 940, 355, 210, 24, { fontSize: 17, bold: true, color: C.red, autoFit: "none" });
  text(slide, "Keeps uploaded files\ntogether", 940, 392, 210, 55, { fontSize: 20, bold: true, autoFit: "none" });

  slide.shapes.connect(browser, services, {
    kind: "straight", fromSide: "right", toSide: "left", line: { fill: C.red, width: 3 }, tail: { type: "arrow", width: "med", length: "med" },
  });
  slide.shapes.connect(services, data, {
    kind: "elbow", fromSide: "right", toSide: "left", line: { fill: C.red, width: 3 }, tail: { type: "arrow", width: "med", length: "med" },
  });
  slide.shapes.connect(services, files, {
    kind: "elbow", fromSide: "right", toSide: "left", line: { fill: C.red, width: 3 }, tail: { type: "arrow", width: "med", length: "med" },
  });

  rect(slide, 72, 522, 1112, 92, C.paleRed, { geometry: "roundRect", borderRadius: 16 });
  text(slide, "AI STATUS", 96, 545, 118, 24, { fontSize: 17, bold: true, color: C.red, autoFit: "none" });
  text(slide, "The current system uses defined workflow rules. Authorized people make every approval decision.", 230, 536, 915, 48, {
    fontSize: 24, bold: true, color: C.ink, autoFit: "none",
  });
  addSlideNumber(slide, 10);
  addNotes(slide, {
    speaker: "Presenter 3",
    time: "0:55",
    visual: "Editable architecture diagram using plain-language labels for browser, services, database, and file storage.",
    say: "Behind the screen, the web portal connects to application services that apply access rules, check requirements, and move each proposal through its status flow. The database keeps records and history, while separate file storage holds uploaded documents. The current system does not use AI to approve or reject proposals. Authorized people make those decisions, and the system provides consistent information for them.",
    transition: "We have also tested whether this foundation can be set up and used reliably.",
    evidence: "Project README architecture; Next.js frontend; Spring Boot services; MariaDB/MySQL; MinIO; repository search found no implemented AI service.",
  });
}

// 11. Progress, limitations, and future
{
  const slide = presentation.slides.add();
  slide.background.fill = C.soft;
  addTitle(slide, "Ready for stakeholder validation", "The core workflow works today, with clear steps before wider rollout");

  text(slide, "36", 72, 170, 120, 70, { fontSize: 58, bold: true, color: C.red, autoFit: "none" });
  text(slide, "backend tests passed", 74, 239, 190, 28, { fontSize: 19, color: C.body, autoFit: "none" });
  text(slide, "12", 290, 170, 100, 70, { fontSize: 58, bold: true, color: C.red, autoFit: "none" });
  text(slide, "browser scenarios passed", 292, 239, 220, 28, { fontSize: 19, color: C.body, autoFit: "none" });
  text(slide, "V61", 544, 170, 130, 70, { fontSize: 58, bold: true, color: C.red, autoFit: "none" });
  text(slide, "clean setup verified", 546, 239, 190, 28, { fontSize: 19, color: C.body, autoFit: "none" });

  rect(slide, 66, 318, 2, 270, C.red);
  text(slide, "READY TODAY", 92, 320, 390, 28, { fontSize: 18, bold: true, color: C.red, autoFit: "none" });
  text(slide, "Core student and review workflow\nCurrent masterlist and active directory\nRepeatable Windows setup and migrations\nProduction frontend build", 92, 366, 475, 178, {
    fontSize: 24, color: C.ink, autoFit: "none", lineSpacing: 1.45,
  });

  rect(slide, 648, 318, 2, 270, C.red);
  text(slide, "NEXT BEFORE WIDER ROLLOUT", 674, 320, 460, 28, { fontSize: 18, bold: true, color: C.red, autoFit: "none" });
  text(slide, "Stakeholder user acceptance testing\nProduction credentials and access policy\nEmail, backup, and deployment configuration\nOptional AI assistance requires policy review", 674, 366, 500, 178, {
    fontSize: 24, color: C.ink, autoFit: "none", lineSpacing: 1.45,
  });
  text(slide, "Planned AI option: document completeness hints or draft summaries. No AI approval decisions.", 92, 619, 1080, 38, {
    fontSize: 20, bold: true, color: C.muted, alignment: "center", autoFit: "none",
  });
  addSlideNumber(slide, 11);
  addNotes(slide, {
    speaker: "Presenter 3",
    time: "1:05",
    visual: "Three verified progress numbers, followed by a clear Ready Today and Next Before Wider Rollout split.",
    say: "The current build has passed 36 backend tests, 12 browser scenarios, and a clean database setup through migration V61. The core student and review workflow is implemented, and the current records travel with a new installation. Before wider rollout, we recommend formal stakeholder user acceptance testing, production credential and access policies, and final email, backup, and deployment configuration. AI assistance could later help identify incomplete documents or summarize drafts, but that capability is planned only and would require stakeholder policy review.",
    transition: "This leaves us with one practical question: what changes when every event has a clear next step?",
    evidence: "Latest Maven test reports; Playwright run; clean V1–V61 migration verification; setup documentation.",
  });
}

// 12. Closing
{
  const slide = presentation.slides.add();
  slide.background.fill = C.red;
  text(slide, "SSC PORTAL", 68, 56, 340, 32, {
    fontSize: 20,
    bold: true,
    color: C.white,
    autoFit: "none",
  });
  text(slide, "Every event begins\nwith a clear next step", 68, 166, 1040, 158, {
    fontSize: 64,
    bold: true,
    color: C.white,
    autoFit: "none",
    lineSpacing: 0.95,
  });
  rect(slide, 68, 378, 94, 7, C.white);
  text(slide, "A shared proposal journey gives students clarity, staff a focused review queue, and stakeholders a process they can follow.", 68, 426, 960, 94, {
    fontSize: 29,
    color: C.white,
    autoFit: "none",
  });
  rect(slide, 68, 574, 586, 74, C.ink, { geometry: "roundRect", borderRadius: 18 });
  text(slide, "Next step: stakeholder user testing", 94, 598, 535, 28, {
    fontSize: 23,
    bold: true,
    color: C.white,
    alignment: "center",
    autoFit: "none",
  });
  text(slide, "Thank you", 1010, 618, 190, 38, {
    fontSize: 26,
    bold: true,
    color: C.white,
    alignment: "right",
    autoFit: "none",
  });
  addNotes(slide, {
    speaker: "Presenter 3",
    time: "0:35",
    visual: "Minimal closing slide in the portal’s primary red, with one recommendation.",
    say: "The expected impact is a proposal process that people can understand and follow. Students know what to do next, staff can focus on the review in front of them, and stakeholders gain clearer visibility from planning through approval. Our recommended next step is stakeholder user testing with real scenarios. Thank you, and we welcome your questions.",
    transition: "Open the floor for stakeholder questions and feedback.",
    evidence: "Synthesis of implemented workflow and verified project status.",
  });
}

const requirements = {
  explicitTotalSlideCount: 12,
  requiredNativeTableOwnerSlides: [],
  requiredNativeChartOwnerSlides: [],
};
const fontPolicy = { basis: "design", families: [FONT] };
const expectedSlideSizeEmu = "12192000,6858000";
const stagingDir = path.join(workspaceDir, ".codex-finalizer");
await fs.mkdir(stagingDir, { recursive: true });
await fs.mkdir(path.dirname(FINAL_PPTX), { recursive: true });
const candidatePath = path.join(stagingDir, "ssc-portal-stakeholder-candidate.pptx");
await (await PresentationFile.exportPptx(presentation)).save(candidatePath);

await finalizePresentation({
  ...requirements,
  workspaceDir,
  candidatePath,
  finalPath: FINAL_PPTX,
  pythonExecutable: RUNTIME_PYTHON,
  integrityValidatorPath: path.join(SKILL_DIR, "container_tools", "inspect_presentation_package_integrity.py"),
  layoutValidatorPath: path.join(SKILL_DIR, "container_tools", "inspect_presentation_layout_geometry.py"),
  layoutArgs: [
    "--expected-slide-size-emu", expectedSlideSizeEmu,
    "--validate-bullet-geometry",
    "--validate-heading-fit",
  ],
  requiredNativeTableOwnerSlides: [],
  fontPolicy,
  verifyArtifactToolImport: true,
  receiptPath: path.join(stagingDir, "SSC-Portal-Stakeholder-Presentation-v7.validation.json"),
});

console.log(FINAL_PPTX);
