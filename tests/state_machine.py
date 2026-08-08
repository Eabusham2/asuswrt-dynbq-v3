LOW=64
MID=128
HIGH=192
LOW_IDLE_PPS=1500
LOW_IDLE_SAMPLES=4
LOW_EXIT_PPS=3000
LOW_EXIT_SAMPLES=1
LOW_PRESS_SAMPLES=4
FULL_SAMPLE_MIN=512
HIGH_POST_PPS=30000
HIGH_SAMPLES=4
HIGH_OUT_MAX=2048
HIGH_HOLD_PPS=20000
HIGH_EXIT_SAMPLES=2
HIGH_TO_LOW_SAMPLES=2

def step(state, pr, cl, hc, hx, pps=0, out=0, full=0, drop=0):
    press=int(full>=FULL_SAMPLE_MIN)
    low_idle=int(pps<=LOW_IDLE_PPS and not press and drop==0)
    high=int(pps>=HIGH_POST_PPS and out<=HIGH_OUT_MAX and not press and drop==0 and pps>0)
    high_hold=int(pps>=HIGH_HOLD_PPS and out<=HIGH_OUT_MAX and not press and drop==0)
    new=state

    if state==MID:
        hx=0
        if drop>0:
            new=LOW; pr=cl=hc=0
        else:
            if press:
                pr+=1; cl=0; hc=0
            else:
                pr=0
                cl=cl+1 if low_idle else 0
                hc=hc+1 if high else 0
            if pr>=LOW_PRESS_SAMPLES:
                new=LOW; pr=cl=hc=0
            elif cl>=LOW_IDLE_SAMPLES:
                new=LOW; pr=cl=hc=0
            elif hc>=HIGH_SAMPLES:
                new=HIGH; pr=cl=hc=0

    elif state==LOW:
        pr=0; hc=0; hx=0
        if drop>0 or press:
            cl=0
        elif pps>=LOW_EXIT_PPS:
            cl+=1
            if cl>=LOW_EXIT_SAMPLES:
                new=MID; cl=0
        else:
            cl=0

    elif state==HIGH:
        pr=0; hc=0
        if drop>0:
            new=LOW; cl=hx=0
        elif press:
            new=MID; cl=hx=0
        else:
            cl=cl+1 if low_idle else 0
            hx=0 if high_hold else hx+1
            if cl>=HIGH_TO_LOW_SAMPLES:
                new=LOW; cl=hx=0
            elif hx>=HIGH_EXIT_SAMPLES:
                new=MID; cl=hx=0
    else:
        new=MID; pr=cl=hc=hx=0

    return new,pr,cl,hc,hx

def exercise_radio(label):
    # MID -> LOW: easier idle entry, four 2-second samples.
    s=(MID,0,0,0,0)
    for _ in range(3): s=step(*s,pps=1000)
    assert s[0]==MID, label
    s=step(*s,pps=1000)
    assert s[0]==LOW, label

    # LOW -> MID: one clearly active sample.
    s=step(*s,pps=4000)
    assert s[0]==MID, label

    # MID -> HIGH: still requires four very-high clean samples.
    for _ in range(3): s=step(*s,pps=40000,out=1500,full=100)
    assert s[0]==MID, label
    s=step(*s,pps=40000,out=1500,full=100)
    assert s[0]==HIGH, label

    # HIGH -> MID: two below-hold samples that are not idle.
    s=step(*s,pps=10000,out=100)
    assert s[0]==HIGH, label
    s=step(*s,pps=10000,out=100)
    assert s[0]==MID, label

    # Re-enter HIGH, then very-low collapses directly to LOW in two samples.
    for _ in range(4): s=step(*s,pps=40000,out=1500,full=50)
    assert s[0]==HIGH, label
    s=step(*s,pps=500,out=0)
    assert s[0]==HIGH, label
    s=step(*s,pps=500,out=0)
    assert s[0]==LOW, label

    # Real BQ drop is immediate LOW from MID or HIGH.
    s=(MID,0,0,0,0); s=step(*s,pps=5000,drop=1)
    assert s[0]==LOW, label
    s=(HIGH,0,0,0,0); s=step(*s,pps=35000,drop=1)
    assert s[0]==LOW, label

    # Severe feeder pressure (>=512) blocks HIGH; smaller counts do not.
    s=(MID,0,0,0,0)
    for _ in range(8): s=step(*s,pps=50000,out=1500,full=600)
    assert s[0]!=HIGH, label

    # Outstanding above the safety ceiling still blocks HIGH.
    s=(MID,0,0,0,0)
    for _ in range(8): s=step(*s,pps=50000,out=2049,full=0)
    assert s[0]==MID, label

    # The empirically observed envelope should be allowed into HIGH.
    s=(MID,0,0,0,0)
    for _ in range(4): s=step(*s,pps=56140,out=1562,full=100)
    assert s[0]==HIGH, label


def run():
    # Exercise the exact same independent state machine for both production radios.
    exercise_radio('wl1')
    exercise_radio('wl2')

    # Independence: loading wl1 must not move idle wl2, and vice versa.
    r1=(LOW,0,0,0,0)
    r2=(LOW,0,0,0,0)
    r1=step(*r1,pps=5000)
    r2=step(*r2,pps=100)
    assert r1[0]==MID and r2[0]==LOW

    for _ in range(4):
        r1=step(*r1,pps=40000,out=1500,full=100)
        r2=step(*r2,pps=100)
    assert r1[0]==HIGH and r2[0]==LOW

    r1=(LOW,0,0,0,0)
    r2=(LOW,0,0,0,0)
    r2=step(*r2,pps=5000)
    assert r1[0]==LOW and r2[0]==MID
    for _ in range(4): r2=step(*r2,pps=40000,out=1500,full=100)
    assert r2[0]==HIGH

    print('state-machine tests: PASS (wl1 + wl2, up/down + independence)')

if __name__=='__main__': run()
