LOW=64
MID=128
HIGH=192
LOW_IDLE_PPS=1000
LOW_IDLE_SAMPLES=6
LOW_EXIT_PPS=2500
LOW_EXIT_SAMPLES=2
LOW_PRESS_SAMPLES=4
FULL_SAMPLE_MIN=512
HIGH_POST_PPS=30000
HIGH_SAMPLES=6
HIGH_OUT_MAX=64
HIGH_HOLD_PPS=20000
HIGH_EXIT_SAMPLES=3
HIGH_TO_LOW_SAMPLES=3

def step(state, pr, cl, hc, hx, pps=0, out=0, full=0, drop=0):
    press=int(full>=FULL_SAMPLE_MIN)
    low_idle=int(pps<=LOW_IDLE_PPS and full==0 and drop==0)
    high=int(pps>=HIGH_POST_PPS and out<=HIGH_OUT_MAX and full==0 and drop==0 and pps>0)
    high_hold=int(pps>=HIGH_HOLD_PPS and out<=HIGH_OUT_MAX and full==0 and drop==0)
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

def run():
    # One pressure burst must not force LOW.
    s=(MID,0,0,0,0)
    s=step(*s,full=1900); s=step(*s,pps=5000)
    assert s[0]==MID

    # Sustained feeder pressure reaches LOW.
    s=(MID,0,0,0,0)
    for _ in range(4): s=step(*s,pps=5000,full=600)
    assert s[0]==LOW

    # LOW stays LOW during genuinely low traffic; it does not bounce to MID.
    for _ in range(10): s=step(*s,pps=100)
    assert s[0]==LOW

    # LOW needs a clearly higher band for two samples to return to MID.
    s=step(*s,pps=3000)
    assert s[0]==LOW
    s=step(*s,pps=3000)
    assert s[0]==MID

    # Very-low traffic must be sustained for 12 seconds before MID -> LOW.
    s=(MID,0,0,0,0)
    for _ in range(5): s=step(*s,pps=100)
    assert s[0]==MID
    s=step(*s,pps=100)
    assert s[0]==LOW

    # Five very-high samples are insufficient; sixth enters HIGH.
    s=(MID,0,0,0,0)
    for _ in range(5): s=step(*s,pps=35000,out=20)
    assert s[0]==MID
    s=step(*s,pps=35000,out=20)
    assert s[0]==HIGH

    # Once HIGH, 20k+ clean traffic holds HIGH without needing 30k entry PPS.
    for _ in range(6): s=step(*s,pps=25000,out=20)
    assert s[0]==HIGH

    # Three below-hold samples return HIGH -> MID.
    for _ in range(2): s=step(*s,pps=10000,out=20)
    assert s[0]==HIGH
    s=step(*s,pps=10000,out=20)
    assert s[0]==MID

    # If HIGH traffic collapses all the way to very-low, drop directly to LOW.
    s=(HIGH,0,0,0,0)
    for _ in range(2): s=step(*s,pps=100,out=0)
    assert s[0]==HIGH
    s=step(*s,pps=100,out=0)
    assert s[0]==LOW

    # Real BQ drop is immediate LOW from MID or HIGH.
    s=(MID,0,0,0,0); s=step(*s,pps=5000,drop=1)
    assert s[0]==LOW
    s=(HIGH,0,0,0,0); s=step(*s,pps=35000,drop=1)
    assert s[0]==LOW

    # HIGH entry is blocked when outstanding work exceeds the safety cap.
    s=(MID,0,0,0,0)
    for _ in range(10): s=step(*s,pps=50000,out=65)
    assert s[0]==MID

    print('state-machine tests: PASS')

if __name__=='__main__': run()
