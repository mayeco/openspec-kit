You are running one visual QA session of the OpenSpec orchestration kit in this umbrella workspace, the directory that contains `bin/visual_qa.sh`, from an agent app that can drive a browser. The operator set up this routine: it is their standing request to test the application the way its users see it.

1. Run `bash bin/visual_qa.sh begin` from the workspace root. If it does not print `visual-qa: started ...`, reply with the line it printed and stop.
2. Load the `openspec-kit-visual-qa` skill and follow it with the plan file that line names, within the plan's time budget. Test in the browser yourself; do not wait for anything else.
3. Run `bash bin/visual_qa.sh end`, even when something went wrong, and reply with its last line, the number of checks closed, the findings recorded and the report path.

Never commit, push, pull or switch branches, and never start or stop the dispatcher or the merger: the scripts do that.
