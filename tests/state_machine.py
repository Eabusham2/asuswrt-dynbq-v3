LOW=64
MID=128
HIGH=192
LOW_PRESS_SAMPLES=4
LOW_CLEAR_SAMPLES=3
FULL_SAMPLE_MIN=512
HIGH_POST_PPS=30000
HIGH_SAMPLES=6
HIGH_OUT_MAX=64
HIGH_EXIT_SAMPLES=3

def step(state, pr, cl, hc, hx, pps=0, out=0, full=0, drop=0, dp=None, dc=None):
    if dp is None: dp=pps*2
    if dc is None: dc=dp
    press=int(full>=FULL_SAMPLE_MIN)
    high=int(pps>=HIGH_POST_PPS and out<=HIGH_OUT_MAX and full==0 and drop==0 and dp>0 and dc*100>=dp*95)
    new=state
    if state==MID:
        cl=0; hx=0
        if drop>0: new=LOW; pr=0; hc=0
        else:
            pr=pr+1 if press else 0
            if pr>=LOW_PRESS_SAMPLES: new=LOW; pr=0; hc=0
            else:
                hc=hc+1 if high else 0
                if hc>=HIGH_SAMPLES: new=HIGH; hc=0
    elif state==LOW:
        pr=0; hc=0; hx=0
        if drop>0 or press: cl=0
        else:
            cl+=1
            if cl>=LOW_CLEAR_SAMPLES: new=MID; cl=0
    elif state==HIGH:
        pr=0; cl=0; hc=0
        if drop>0: new=LOW; hx=0
        elif press: new=MID; hx=0
        elif high: hx=0
        else:
            hx+=1
            if hx>=HIGH_EXIT_SAMPLES: new=MID; hx=0
    return new,pr,cl,hc,hx

def run():
    s=(MID,0,0,0,0)
    s=step(*s,full=1900); s=step(*s)
    assert s[0]==MID
    s=(MID,0,0,0,0)
    for _ in range(4): s=step(*s,full=600)
    assert s[0]==LOW
    for _ in range(3): s=step(*s)
    assert s[0]==MID
    s=(MID,0,0,0,0)
    for _ in range(6): s=step(*s,pps=35000,out=20)
    assert s[0]==HIGH
    for _ in range(3): s=step(*s,pps=1000)
    assert s[0]==MID
    s=(MID,0,0,0,0); s=step(*s,drop=1)
    assert s[0]==LOW
    print('state-machine tests: PASS')

if __name__=='__main__': run()
