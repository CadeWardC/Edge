"""A copy of Sim/PlaneFlight.swift in Python, to try numbers out: take-off roll, top speed, turns, stalls, descents.
Usage: plane.py   (needs numpy)"""
import numpy as np, math
G=9.81; KT=0.5144
def qmul(a,b):
    w1,x1,y1,z1=a; w2,x2,y2,z2=b
    return np.array([w1*w2-x1*x2-y1*y2-z1*z2, w1*x2+x1*w2+y1*z2-z1*y2, w1*y2-x1*z2+y1*w2+z1*x2, w1*z2+x1*y2-y1*x2+z1*w2])
def qaxis(ang,ax): ax=np.array(ax,float); ax/=np.linalg.norm(ax); return np.concatenate([[math.cos(ang/2)],ax*math.sin(ang/2)])
def act(q,v): return qmul(qmul(q,np.concatenate([[0],v])),q*np.array([1,-1,-1,-1]))[1:]
def angles(q):
    f=act(q,[1,0,0]); u=act(q,[0,1,0]); p=math.asin(max(-1,min(1,f[1]))); h=math.atan2(-f[2],f[0])
    lr=np.cross(f,[0,1,0]); lr/=np.linalg.norm(lr); lu=np.cross(lr,f); return h,p,math.atan2(u@lr,u@lu)
def orient(h,p,r): return qmul(qmul(qaxis(h,[0,1,0]),qaxis(p,[0,0,1])),qaxis(r,[1,0,0]))
class Plane:
    ML=1.4; SA=0.26; RL=0.25
    def __init__(s,stall,top,power,roll,pitch,yaw):
        s.vs=stall*KT; s.vt=top*KT; s.T=power*G; s.rr=math.radians(roll); s.pr=math.radians(pitch); s.yr=math.radians(yaw)
        s.kl=G/(s.ML*s.vs**2); s.ki=s.kl/(math.pi*6); lt=s.ML*(s.vs/s.vt)**2; a=s.T/s.vt**2; s.kd=max(a-s.ki*lt*lt,a*.15)
    def fly(s,st,inp,dt):
        V=np.linalg.norm(st['v']); q=st['q']; loc=act(q*np.array([1,-1,-1,-1]),st['v']); mov=V>3
        att=math.atan2(-loc[1],loc[0]) if mov else 0; slip=max(-.6,min(.6,math.atan2(loc[2],max(abs(loc[0]),.1)))) if mov else 0
        L=s.RL+(s.ML-s.RL)/s.SA*att
        if att>s.SA:
            L=max(s.ML-2.8*(att-s.SA),.45)
            if att>1.2: L=.2
        L=max(L,-.9)
        if abs(att)>1.5: L=0
        s.stalled=mov and att>s.SA and not st['g']; s.att=att
        f=act(q,[1,0,0]); r=act(q,[0,0,1])
        acc=np.array([0,-G,0])+f*s.T*inp['t']
        if mov:
            d=st['v']/V; P=V*V; ld=np.cross(r,d)
            acc+=ld/np.linalg.norm(ld)*s.kl*P*L
            b=max(0,math.sin(att)**2-math.sin(s.SA)**2)
            acc-=d*(s.kd+s.ki*L*L+s.kl*1.5*b)*P; acc-=r*s.kl*2*P*math.sin(slip)
        st['v']=st['v']+acc*dt; st['p']=st['p']+st['v']*dt
        grip=min(1,(V/(.9*s.vs))**2); steady=min(1,V/s.vs); pl=min(s.pr,6*G/max(V,1))
        c=lambda v: v*(.45+.55*abs(v))
        w=np.array([c(inp['r'])*s.rr*grip,-c(inp['y'])*s.yr*grip,c(inp['p'])*pl*grip])
        if mov and not st['g']:
            ex=att-min(max(att,-.1),.17); w[2]-=2*ex*steady; w[1]-=1.6*slip*steady
        st['w']=st['w']+(w-st['w'])*min(1,8*dt)
        t=np.linalg.norm(st['w'])*dt
        if t>1e-6: q=qmul(q,qaxis(t,st['w'])); st['q']=q/np.linalg.norm(q)
    def taxi(s,st,inp,dt):
        h,p,r=angles(st['q']); r*=math.exp(-10*dt); p=min(max(p,0),.28)
        g=np.array([st['v'][0],0,st['v'][2]]); sp=np.linalg.norm(g)
        if sp<s.vs*.5: p*=math.exp(-3*dt)
        h-=min(max(inp['y']+.6*inp['r'],-1),1)*.7*min(1,sp/4)*dt
        st['q']=orient(h,p,r); st['w'][0]=0; st['w'][1]=0
        side=np.array([math.sin(h),0,math.cos(h)]); g-=side*(g@side)*min(1,12*dt)
        sl=(.4+(5 if inp['t']<.05 else 0))*dt; l=np.linalg.norm(g); g=g*((l-sl)/l) if l>sl else g*0
        st['v'][0]=g[0]; st['v'][2]=g[2]
def step(pl,st,inp,dt,gear=1.5):
    pl.fly(st,inp,dt)
    if st['p'][1]<=gear:
        st['p'][1]=gear
        if st['v'][1]<0: st['v'][1]=0
        st['g']=True; pl.taxi(st,inp,dt)
    elif st['p'][1]>gear+.3: st['g']=False
def new(y=1.5,v=0): return dict(p=np.array([0,y,0.]),v=np.array([v,0,0.]),q=np.array([1,0,0,0.]),w=np.zeros(3),g=y<=1.5)
for name,args in (("hopper",(45,125,.34,85,40,22)),("bumble",(34,92,.36,110,48,30)),("jet",(95,320,.8,190,46,18))):
    pl=Plane(*args); dt=1/120
    # takeoff: full throttle, pull 0.5 back once past 1.1 stall
    st=new(); t=0; lift=None
    while t<60:
        V=np.linalg.norm(st['v']); inp=dict(t=1,p=0.5 if V>1.1*pl.vs else 0,r=0,y=0)
        step(pl,st,inp,dt); t+=dt
        if lift is None and not st['g']: lift=(t,st['p'][0],V/KT)
        if st['p'][1]>150: break
    h,p,r=angles(st['q'])
    print(name,"liftoff t=%.1fs roll=%.0fm at %.0fkt"%lift,"| 150m at t=%.1f pitch=%.0fdeg V=%.0fkt stalled=%s"%(t,math.degrees(p),np.linalg.norm(st['v'])/KT,pl.stalled))
    # level cruise hands-off from in-air start: does it hold? full throttle 60 s
    st=new(600,pl.vs+(pl.vt-pl.vs)*.6)
    for i in range(int(90/dt)): step(pl,st,dict(t=1,p=0,r=0,y=0),dt)
    h,p,r=angles(st['q']); print("  hands-off full thr 90s: alt=%.0f V=%.0fkt (top %.0f) pitch=%.1f vs=%.1f"%(st['p'][1],np.linalg.norm(st['v'])/KT,args[1],math.degrees(p),st['v'][1]))
    # banked turn: roll right 1s then hold, slight back stick
    st=new(600,pl.vs*1.6)
    for i in range(int(20/dt)):
        t=i*dt; h,p,r=angles(st['q'])
        inp=dict(t=.8,p=.25,r=(1 if r<math.radians(40) else 0) if t>1 else 0,y=0); step(pl,st,inp,dt)
    h,p,r=angles(st['q']); print("  turn 20s: heading change=%.0fdeg bank=%.0f alt=%.0f V=%.0fkt slip_att=%.1f"%(math.degrees(h),math.degrees(r),st['p'][1],np.linalg.norm(st['v'])/KT,math.degrees(pl.att)))
    # stall: idle, hold full back
    st=new(600,pl.vs*1.3); mn=1e9; stalled=False
    for i in range(int(25/dt)):
        step(pl,st,dict(t=0,p=1,r=0,y=0),dt); stalled|=bool(pl.stalled)
    h,p,r=angles(st['q']); print("  idle+full back 25s: stalled=%s alt=%.0f V=%.0fkt pitch=%.0f vs=%.1f"%(stalled,st['p'][1],np.linalg.norm(st['v'])/KT,math.degrees(p),st['v'][1]))
    # glide approach: idle hands off from 100 m
    st=new(100,pl.vs*1.4); t=0
    while not st['g'] and t<120: step(pl,st,dict(t=0.15,p=0,r=0,y=0),dt); t+=dt; last=st['v'].copy() if not st['g'] else last
    print("  hands-off 15%% thr descent: touch t=%.0fs sink=%.1f m/s V=%.0fkt"%(t,-last[1],np.linalg.norm(last)/KT))
