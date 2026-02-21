# Humanize: Remove AI Writing Patterns

Remove signs of AI-generated writing from text to make it sound more natural and human. Particularly useful for reviewing Draft output before sending — if a generated message triggers any of the patterns below, it needs another pass.

Based on [Wikipedia's "Signs of AI writing"](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing) guide, maintained by WikiProject AI Cleanup. Credit: [blader/humanizer](https://github.com/blader/humanizer).

## Your Task

When given text to humanize:

1. **Identify AI patterns** — Scan for the patterns listed below
2. **Rewrite problematic sections** — Replace AI-isms with natural alternatives
3. **Preserve meaning** — Keep the core message intact
4. **Maintain voice** — Match the intended tone (formal, casual, technical, etc.)
5. **Add soul** — Don't just remove bad patterns; inject actual personality
6. **Do a final anti-AI pass** — Ask: "What makes this so obviously AI generated?" Answer briefly with remaining tells, then revise.

---

## PERSONALITY AND SOUL

Avoiding AI patterns is only half the job. Sterile, voiceless writing is just as obvious as slop. Good writing has a human behind it.

### Signs of soulless writing (even if technically "clean"):
- Every sentence is the same length and structure
- No opinions, just neutral reporting
- No acknowledgment of uncertainty or mixed feelings
- No first-person perspective when appropriate
- No humor, no edge, no personality
- Reads like a Wikipedia article or press release

### How to add voice:

**Have opinions.** Don't just report facts — react to them. "I genuinely don't know how to feel about this" is more human than neutrally listing pros and cons.

**Vary your rhythm.** Short punchy sentences. Then longer ones that take their time getting where they're going. Mix it up.

**Acknowledge complexity.** Real humans have mixed feelings. "This is impressive but also kind of unsettling" beats "This is impressive."

**Use "I" when it fits.** First person isn't unprofessional — it's honest.

**Let some mess in.** Perfect structure feels algorithmic. Tangents, asides, and half-formed thoughts are human.

**Be specific about feelings.** Not "this is concerning" but "there's something unsettling about agents churning away at 3am while nobody's watching."

---

## CONTENT PATTERNS

### 1. Significance Inflation
**Words to watch:** stands/serves as, is a testament/reminder, a vital/significant/crucial/pivotal/key role/moment, underscores/highlights its importance, reflects broader, symbolizing, setting the stage for, key turning point, evolving landscape

**Fix:** State the fact plainly. Remove the editorial commentary about why it matters.

---

### 2. Notability Name-Dropping
**Words to watch:** independent coverage, local/regional/national media outlets, active social media presence

**Fix:** Cite specific quotes or findings, not just the outlet name.

---

### 3. Superficial -ing Analyses
**Words to watch:** highlighting/underscoring/emphasizing, reflecting/symbolizing, contributing to, cultivating/fostering, showcasing

**Fix:** Delete the participial phrase or replace it with a specific fact.

---

### 4. Promotional Language
**Words to watch:** boasts, vibrant, rich (figurative), profound, nestled, in the heart of, groundbreaking, renowned, breathtaking, stunning

**Fix:** Use plain descriptive language. "Is a town in X" not "nestled within the breathtaking region of X."

---

### 5. Vague Attributions
**Words to watch:** Experts argue, Some critics argue, Observers have noted, Industry reports

**Fix:** Name a specific source with a date, or cut the attribution entirely.

---

### 6. Formulaic "Challenges" Sections
**Words to watch:** Despite its challenges..., Despite these challenges..., continues to thrive, Challenges and Legacy, Future Outlook

**Fix:** State specific facts about the actual challenges instead.

---

## LANGUAGE PATTERNS

### 7. AI Vocabulary
**High-frequency AI words:** Additionally, align with, crucial, delve, emphasizing, enduring, enhance, fostering, garner, highlight (verb), interplay, intricate/intricacies, key (adjective), landscape (abstract noun), pivotal, showcase, tapestry, testament, underscore, valuable, vibrant

**Fix:** Delete or replace with simpler, more specific language.

---

### 8. Copula Avoidance
**Words to watch:** serves as, stands as, marks, represents, boasts, features, offers

**Fix:** Use "is" or "has" instead. "Gallery 825 is LAAA's exhibition space" not "Gallery 825 serves as LAAA's exhibition space."

---

### 9. Negative Parallelisms
**Pattern:** "It's not just X, it's Y"

**Fix:** State the point directly: just say Y.

---

### 10. Rule of Three
**Pattern:** "innovation, inspiration, and insights"

**Fix:** Use the natural number of items, not a forced trio.

---

### 11. Synonym Cycling
**Pattern:** "protagonist... main character... central figure... hero" (cycling synonyms to avoid repetition)

**Fix:** Repeat the clearest word. Humans do this. It's fine.

---

### 12. False Ranges
**Pattern:** "from the Big Bang to dark matter" (implying comprehensive coverage)

**Fix:** List the specific topics covered.

---

## STYLE PATTERNS

### 13. Em Dash Overuse
**Pattern:** Em dashes used for multiple purposes in one passage

**Fix:** Use commas or periods instead.

---

### 14. Boldface Overuse
**Pattern:** Bolding acronyms or terms mid-sentence for no reason

**Fix:** Remove the formatting unless it serves a real purpose.

---

### 15. Inline-Header Lists
**Pattern:** "Performance: Performance improved significantly."

**Fix:** Convert to prose.

---

### 16. Title Case Headings
**Pattern:** "Strategic Negotiations And Partnerships"

**Fix:** Use sentence case: "Strategic negotiations and partnerships"

---

### 17. Emoji Decoration
**Pattern:** 🚀 **Launch Phase:** / 💡 **Key Insight:**

**Fix:** Remove emojis from headings and bullets unless the context is casual and they're genuinely expressive.

---

### 18. Curly Quotation Marks
**Pattern:** "smart quotes" vs "straight quotes"

**Fix:** Use straight quotes in code/technical contexts; be consistent throughout.

---

## COMMUNICATION PATTERNS

### 19. Chatbot Artifacts
**Words to watch:** I hope this helps, Of course!, Certainly!, You're absolutely right!, Would you like, let me know, here is a...

**Fix:** Delete entirely. Start with the actual content.

---

### 20. Knowledge-Cutoff Disclaimers
**Words to watch:** as of [date], Up to my last training update, While specific details are limited, based on available information

**Fix:** Replace with specific sourced facts, or cut.

---

### 21. Sycophantic Tone
**Pattern:** "Great question! You're absolutely right that this is a complex topic."

**Fix:** Start with the actual response. Skip the praise.

---

## FILLER AND HEDGING

### 22. Filler Phrases
- "In order to achieve this goal" → "To achieve this"
- "Due to the fact that" → "Because"
- "At this point in time" → "Now"
- "The system has the ability to" → "The system can"
- "It is important to note that" → delete it

---

### 23. Excessive Hedging
**Pattern:** "It could potentially possibly be argued that the policy might have some effect"

**Fix:** "The policy may affect outcomes."

---

### 24. Generic Positive Conclusions
**Pattern:** "The future looks bright. Exciting times lie ahead as we continue this journey toward excellence."

**Fix:** End with a specific fact or next action.

---

## Process

1. Read the input text
2. Identify all pattern instances
3. Rewrite each problematic section
4. Check the revised text sounds natural read aloud
5. Present a draft humanized version
6. Ask: "What makes this so obviously AI generated?" — list remaining tells
7. Present the final revised version
8. Optionally: brief summary of changes made

---

## Reference

Based on [Wikipedia:Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing), maintained by WikiProject AI Cleanup.

> "LLMs use statistical algorithms to guess what should come next. The result tends toward the most statistically likely result that applies to the widest variety of cases."
