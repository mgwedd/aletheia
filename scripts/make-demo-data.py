#!/usr/bin/env python3
"""Builds a fictional Aletheia library for demos and screenshots.

    python3 scripts/make-demo-data.py [folder]      # default: ~/aletheia-demo-data

Every patient and session is made up. Each session has a mock transcript and
nothing else: generate progress notes and Ask answers in the app with the real
model. Point Aletheia at the folder with Settings > Data folder > Choose another
folder… (or the first-run checklist). The app adds its database and search
index on first open.

Rerunning replaces a folder this script made; any other folder is refused.
"""
import datetime as dt
import json
import os
import shutil
import sys
import uuid

MARKER = ".aletheia-demo-data"
SCHEMA = {"schemaVersion": 2, "lastWrittenBy": "demo-data"}

# name -> list of sessions, oldest first; each is a list of (speaker, line).
# "Y" is the therapist ("You"), "C" the client on the call ("Call audio").
PATIENTS = {
    "Avery Lindqvist": [
        [("Y", "Thanks for coming in. What would you like to focus on to begin with?"),
         ("C", "Work, mostly. I'm a product lead and since the reorg I can't switch off. I answer email at midnight."),
         ("Y", "What happens if you don't answer?"),
         ("C", "I lie there imagining my manager reading it and deciding I'm slow."),
         ("Y", "How is your sleep?"),
         ("C", "Five hours on a good night. I wake at four with my heart going."),
         ("Y", "Has anything helped, even a little?"),
         ("C", "Running, when I make time for it. Which is never lately."),
         ("Y", "Let's keep a simple log this week: bedtime, waking, and what was on your mind at four."),
         ("C", "I can do that. I like having something concrete.")],
        [("Y", "How did the sleep log go?"),
         ("C", "It was eye-opening. Every four a.m. wake-up was the night before a presentation."),
         ("Y", "So the mind is rehearsing. What does it predict?"),
         ("C", "That I'll freeze, someone will ask a question I can't answer, and that's it."),
         ("Y", "That's it meaning?"),
         ("C", "That they'll see I'm not as good as they thought."),
         ("Y", "What has actually happened in past presentations?"),
         ("C", "Honestly they go fine. People say they're clear."),
         ("Y", "Let's notice that gap between the prediction and the record. One idea: no email after eight, as an experiment."),
         ("C", "That feels risky, but okay. One week.")],
        [("Y", "Good to see you again. How was the week with the evening boundary?"),
         ("C", "Better in some ways. No email after eight, and I slept through three nights."),
         ("Y", "That's a real change. What made those nights different?"),
         ("C", "I stopped rehearsing tomorrow's meetings. On the bad nights I'd already decided the presentation would go wrong."),
         ("Y", "When you notice yourself predicting the worst, what happens in your body?"),
         ("C", "My chest gets tight and I check my phone, like I can head it off by being ready."),
         ("Y", "When the tightness starts, what's the first thought that shows up?"),
         ("C", "That if I make one mistake my manager will see I'm not good enough."),
         ("Y", "That's a heavy rule to live under. Where do you think you first learned it?"),
         ("C", "Probably at home. Grades were the only thing that got noticed."),
         ("Y", "For next time, try a thought record when the prediction shows up: the thought, the evidence, and what a friend would say."),
         ("C", "Okay. I'll try it before Thursday's review.")],
        [("Y", "How did Thursday's review go?"),
         ("C", "I did the thought record the night before. The prediction was ninety percent sure I'd freeze."),
         ("Y", "And what happened?"),
         ("C", "One tough question. I said I'd follow up, and my manager just nodded. Nobody cared."),
         ("Y", "How sure would you be now, for the next one?"),
         ("C", "Maybe forty percent. It's still there, but quieter."),
         ("Y", "That's a big shift in a few weeks. What about the four a.m. waking?"),
         ("C", "Twice this week instead of every night. And I ran on Saturday."),
         ("Y", "Let's talk about keeping this going when the next busy stretch comes."),
         ("C", "Yes. Quarter end is in three weeks and that's when it always falls apart.")],
    ],
    "Jordan Okafor": [
        [("Y", "You mentioned on the phone that things have been hard since the move. Tell me about that."),
         ("C", "We moved for my partner's job. I left my friends, my team, everything. I work from home now and some days I don't speak to anyone."),
         ("Y", "How long has it been?"),
         ("C", "Five months. I thought it would get easier."),
         ("Y", "What does a typical evening look like?"),
         ("C", "My partner gets home tired, we eat, I scroll. I feel flat."),
         ("Y", "Flat, like low in mood, or like nothing feels like much?"),
         ("C", "Nothing feels like much. I used to play five-a-side every week."),
         ("Y", "That's worth holding on to. What would it take to find a team here?"),
         ("C", "Looking it up, I suppose. It feels like a lot of effort.")],
        [("Y", "Last time you talked about five-a-side. Did you look anything up?"),
         ("C", "I found a league ten minutes away. I haven't emailed them."),
         ("Y", "What gets in the way?"),
         ("C", "Walking in where everyone already knows each other. I'll be the new person again."),
         ("Y", "What's the worst part of being the new person?"),
         ("C", "Standing there not knowing what to say."),
         ("Y", "Have you been the new person before and come through it?"),
         ("C", "At my old job. It took a month and then they were my best friends."),
         ("Y", "So you have some evidence. Could we break it into one small step this week?"),
         ("C", "I'll send the email. Just the email.")],
        [("Y", "How did the email go?"),
         ("C", "They replied in an hour. I went on Tuesday."),
         ("Y", "How was it?"),
         ("C", "Awkward for ten minutes, then fine. One of them works near me and we got a coffee."),
         ("Y", "How did you feel afterwards?"),
         ("C", "Tired, but the good kind. First time in months I looked forward to a week."),
         ("Y", "What do you notice about the gap between how hard it felt and how it went?"),
         ("C", "The dread was worse than the thing. That's probably true of a lot of stuff."),
         ("Y", "Let's keep that in mind as we look at the other areas you mentioned, like talking to your partner about how the move has been."),
         ("C", "Yes. That one I've been avoiding too.")],
    ],
    "Sam Reyes": [
        [("Y", "Where would you like to start today?"),
         ("C", "My dad's diagnosis. It's early-stage, they say it's treatable, but I can't stop thinking about it."),
         ("Y", "When did you find out?"),
         ("C", "Three weeks ago. I've driven up every weekend since."),
         ("Y", "That's a lot to carry, and a lot of driving. How are you looking after yourself in it?"),
         ("C", "I'm not, really. I'm the one who handles things. My brother is useless at this."),
         ("Y", "What happens when you imagine letting someone else handle a piece of it?"),
         ("C", "I feel guilty. Like I'm abandoning him."),
         ("Y", "Let's make space for that guilt, and also for how tired you sound."),
         ("C", "I am tired. I didn't realise until I said it.")],
        [("Y", "How was the weekend with your dad?"),
         ("C", "Better. He started treatment and he's in good spirits, better than me honestly."),
         ("Y", "What's that like, seeing him cope better than you?"),
         ("C", "A relief, and a bit embarrassing. He's the one who's ill."),
         ("Y", "Your worry is a sign of how much he matters to you. Did anything change with your brother?"),
         ("C", "I asked him to take the hospital run on Wednesdays. He said yes straight away."),
         ("Y", "How did that feel?"),
         ("C", "Strange. Like I'd been holding a door that didn't need holding."),
         ("Y", "That's a striking image. Where else might you be holding doors?"),
         ("C", "Work, probably. I'll think about it.")],
        [("Y", "You said you'd think about the doors. What came up?"),
         ("C", "I do it at work too. I cover for people so nobody's let down, then resent it."),
         ("Y", "What would happen if you didn't cover?"),
         ("C", "Someone might be disappointed in me."),
         ("Y", "And then?"),
         ("C", "Then I'd survive it, I suppose. My dad said something like that. He said stop being the family's emergency services."),
         ("Y", "How did that land?"),
         ("C", "I laughed, then I cried in the car."),
         ("Y", "It sounds like it touched something true. Let's look at one situation at work this week where you could let a door close."),
         ("C", "There's a rota I always fill. I'll leave a gap and see what happens.")],
    ],
    "Priya Natarajan": [
        [("Y", "What brings you in?"),
         ("C", "I've had two panic attacks on the train. Now I take the bus, which takes an hour longer."),
         ("Y", "Can you walk me through the first one?"),
         ("C", "It was packed, the train stopped in a tunnel, and suddenly I couldn't breathe. I thought I was having a heart attack."),
         ("Y", "That sounds frightening. What did you do?"),
         ("C", "I got off at the next stop and sat on a bench for half an hour."),
         ("Y", "Have you seen a doctor about the physical symptoms?"),
         ("C", "Yes, my heart is fine. They said it was panic."),
         ("Y", "That's helpful to know. Panic is very uncomfortable but not dangerous. Next time I'd like to explain what's happening in the body during an attack."),
         ("C", "Please. Not understanding it is half of what scares me.")],
        [("Y", "Last time we went through the panic cycle. How has the week been?"),
         ("C", "I read the handout twice. When my heart raced at work I told myself it was adrenaline, not a heart attack."),
         ("Y", "What happened then?"),
         ("C", "It peaked and came down in about five minutes. That's never happened before."),
         ("Y", "That's the cycle breaking. How do you feel about the train now?"),
         ("C", "Still nervous. But I'd like to try one stop, off-peak."),
         ("Y", "Let's plan it together: which stop, what time, and what you'll do if the feelings rise."),
         ("C", "Saturday morning, one stop, and I'll breathe slowly and let it peak."),
         ("Y", "And notice what actually happens, rather than what the fear predicts."),
         ("C", "Okay. I'll write it down after.")],
    ],
    "Theo Marchetti": [
        [("Y", "Last time you said the arguments with your partner were getting more frequent. How has it been?"),
         ("C", "Same. It's always about chores on the surface, but really it's that we don't see each other."),
         ("Y", "Tell me about the last one."),
         ("C", "She said I never plan anything. I said she never notices what I do. Then we both went quiet for two days."),
         ("Y", "What did you feel underneath the anger?"),
         ("C", "Lonely, I think. Like we're flatmates."),
         ("Y", "Have you ever said that to her, in those words?"),
         ("C", "No. It sounds dramatic."),
         ("Y", "It sounds honest. What would it be like to say it when you're both calm?"),
         ("C", "Scary. But maybe better than another two days of silence.")],
        [("Y", "Did you find a calm moment to talk?"),
         ("C", "Sunday, on a walk. I said I miss her. She said she'd been feeling the same."),
         ("Y", "How was that for you?"),
         ("C", "Relief. We'd both been waiting for the other to say it."),
         ("Y", "What came out of the conversation?"),
         ("C", "We're going to protect Friday evenings. No phones, no friends, just us."),
         ("Y", "What might get in the way?"),
         ("C", "Work, my shifts change a lot. And I go quiet when I'm stressed."),
         ("Y", "Let's think about how you could tell her you're stressed without going quiet."),
         ("C", "Maybe just say it. I'm stressed, it isn't about you.")],
        [("Y", "How did the first Friday evening go?"),
         ("C", "We cooked together. It was really nice. The second one I got called into work."),
         ("Y", "How did you handle that?"),
         ("C", "I told her straight away and we moved it to Saturday. Old me would have just not mentioned it until it was too late."),
         ("Y", "That's a change. What did she say?"),
         ("C", "She said thanks for telling me. No argument."),
         ("Y", "How have the chore arguments been?"),
         ("C", "One small one, but it ended in a joke. Feels different."),
         ("Y", "It sounds like you're both turning towards each other more. Let's look at what still feels stuck."),
         ("C", "Money. We avoid talking about money.")],
    ],
    "Maya Chen-Holloway": [
        [("Y", "Welcome. What made you decide to reach out now?"),
         ("C", "I start a new job in a month and I want to stop procrastinating before it starts. At my last job it got really bad."),
         ("Y", "What did it look like at its worst?"),
         ("C", "I'd leave a report until the night before, pull an all-nighter, then feel awful for days."),
         ("Y", "What goes through your mind when you sit down to start?"),
         ("C", "That it has to be perfect, so I'd better wait until I have a big block of time."),
         ("Y", "And the big block of time rarely comes."),
         ("C", "Never. So I end up with the worst block of time, the night before."),
         ("Y", "Let's experiment with the opposite: starting badly, for ten minutes, on purpose."),
         ("C", "Starting badly. I like that. It takes the pressure off.")],
    ],
}

def stamp(seconds):
    return f"[{seconds // 60:02d}:{seconds % 60:02d}]"

def transcript(lines):
    out, t = [], 4
    for who, text in lines:
        out.append(f"{stamp(t)} {'You' if who == 'Y' else 'Call audio'}: {text}")
        t += 9 + len(text) // 9
    return "\n".join(out) + "\n"

def iso(when):
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, 0o600)

def mkdir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)

def main():
    root = os.path.abspath(os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/aletheia-demo-data"))
    if os.path.exists(root):
        if not os.path.exists(os.path.join(root, MARKER)):
            sys.exit(f"{root} exists and was not made by this script; refusing to replace it.")
        shutil.rmtree(root)
    mkdir(root)
    write(os.path.join(root, MARKER), "Fictional demo library made by scripts/make-demo-data.py.\n")
    write(os.path.join(root, ".aletheia.json"), json.dumps(SCHEMA, indent=2) + "\n")
    mkdir(os.path.join(root, "Patients"))

    now = dt.datetime.now().astimezone().replace(second=0, microsecond=0)
    for index, (name, sessions) in enumerate(PATIENTS.items()):
        pid = str(uuid.uuid4()).upper()
        pdir = os.path.join(root, "Patients", pid)
        mkdir(pdir)
        # Weekly sessions; the first patient's newest is the most recent.
        newest = (now - dt.timedelta(days=1 + index)).replace(hour=10 + index % 6, minute=0)
        first = newest - dt.timedelta(weeks=len(sessions) - 1)
        patient = {
            "id": pid, "slug": pid, "name": name, "notes": "", "clinicalHistory": "",
            "medications": [], "createdAt": iso(first - dt.timedelta(days=2)),
            "recordingConsentAttestedAt": iso(first - dt.timedelta(days=2)),
        }
        write(os.path.join(pdir, "patient.json"), json.dumps(patient, indent=2, sort_keys=True) + "\n")
        for week, lines in enumerate(sessions):
            when = first + dt.timedelta(weeks=week)
            sdir = os.path.join(pdir, f"{when.strftime('%Y-%m-%d')}_Session")
            mkdir(sdir)
            meta = {"id": str(uuid.uuid4()).upper(), "date": iso(when)}
            write(os.path.join(sdir, "session.json"), json.dumps(meta, indent=2, sort_keys=True) + "\n")
            write(os.path.join(sdir, "transcript.txt"), transcript(lines))
    total = sum(len(s) for s in PATIENTS.values())
    print(f"Wrote {len(PATIENTS)} fictional patients and {total} transcribed sessions to {root}")

if __name__ == "__main__":
    main()
