10 CLS
20 N1 = 0 : N2 = 1: MAX = 20000
30 SUM = N1+N2
40 N1 = N2
50 N2 = SUM
60 PRINT N1,
70 goto (N1<MAX)*30 + (N1>=MAX)*99
