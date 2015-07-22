#!/bin/bash
svn commit -m '[minor] Beginning distributed table generation'
ssh bcpierce@ds01.seas.upenn.edu 'source ~/.bash_profile; cd ~/safeqc; svn up; cd tmu; make'
ssh -f bcpierce@ds02.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds02.sh'
ssh -f bcpierce@ds03.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds03.sh'
ssh -f bcpierce@ds04.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds04.sh'
ssh -f bcpierce@ds05.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds05.sh'
ssh -f bcpierce@ds06.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds06.sh'
ssh -f bcpierce@ds07.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds07.sh'
ssh -f bcpierce@ds08.seas.upenn.edu 'cd ~/safeqc/tmu; ./cmds-ds08.sh'