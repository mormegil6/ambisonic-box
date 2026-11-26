#!/usr/bin/env python3
"""A second reading of a run, for browsers whose frame callback does not fire for every frame (Firefox).
usage: python3 analyze-mediatime.py <tag> [<tag> ...]      (reads runs/<tag>.json and runs/<tag>.wav, like analyze.py)
A is analyze.py's estimate: the flash is timed by the first callback that shows a bright frame. If the callback skips
the first bright frame, that time is one frame late and the audio reads early. B times the flash from the frames' media
time instead: the flash's media time is the earliest phase seen in the run, and media time is mapped to the page clock
by the median of (callback time - media time) over the frames within 1 s of the flash. Positive = audio late."""
import json, subprocess, sys, numpy as np, collections
sr=48000; W=240
def run(tag):
    d=json.load(open(f'runs/{tag}.json'))
    raw=subprocess.run(['ffmpeg','-v','error','-i',f'runs/{tag}.wav','-f','f32le','-ac','1','-ar','48000','-'],capture_output=True).stdout
    a=np.frombuffer(raw,dtype=np.float32).astype(np.float64)
    def env(f):
        z=a*np.exp(-2j*np.pi*f*np.arange(len(a))/sr); c=np.cumsum(np.concatenate([[0],z])); return np.abs((c[W:]-c[:-W])/W)*2
    def onsets(e,frac,gap):
        thr=e.max()*frac; idx=[]; last=-10**9
        for i in np.where(e>thr)[0]:
            if i-last>gap*sr: idx.append(i)
            last=i
        out=[]
        for i in idx:
            seg=e[max(0,i-W):i+int(0.1*sr)]; out.append((max(0,i-W)+int(np.argmax(seg>seg.max()*0.5)))/sr)
        return out
    clk=onsets(env(3000),0.4,0.3)[:3]; ep=d['clicks']['epochMs']; cal=np.mean([ep[i]-clk[i]*1000 for i in range(3)])
    beeps=[t*1000+cal for t in onsets(env(1000),0.5,2.0) if t>clk[-1]+0.4]
    L=sorted(d['lum'],key=lambda r:r[0]); T=[]; 
    for now,edt,md,y in L:
        T.append((d['timeOrigin']+(edt if edt and abs(edt-now)<1000 else now), md, y, d['timeOrigin']+now))
    T=np.array(T)
    # estimator A (as analyze.py): time of the first bright callback
    A=[]; firstmd=[]; prev=True; last=-1e9
    for t,md,y,_ in T:
        if y<0.2: prev=True
        elif y>0.5 and prev and t-last>2000: A.append(t); firstmd.append(md); last=t; prev=False
    A=np.array(A); firstmd=np.array(firstmd)
    # estimator B: wall = media*1000 + c, c fitted on frames near each flash; the flash's media time is the earliest phase seen
    ph=np.mod(firstmd,4.0); md0=ph.min()
    B=[]
    for t,m in zip(A,firstmd):
        k=np.round((m-md0)/4.0); mflash=md0+4*k
        sel=(np.abs(T[:,1]-mflash)<1.0)
        dl=T[sel,0]-T[sel,1]*1000
        B.append((mflash*1000+np.median(dl), mflash*1000+np.percentile(dl,10), mflash*1000+dl.mean()))
    B=np.array(B)
    def off(F):
        r=[]
        for be in beeps:
            j=np.argmin(np.abs(F-be)); 
            if abs(F[j]-be)<2000: r.append(be-F[j])
        return np.array(r)
    rA=off(A); rm=off(B[:,0]); rl=off(B[:,1]); rmean=off(B[:,2])
    steps=collections.Counter(np.round(np.diff(T[50:,1])*1000)).most_common(3)
    iv=np.diff(T[50:,3]); 
    late=np.round((firstmd-(md0+4*np.round((firstmd-md0)/4)))*1000)
    print(f"{tag:22s} {d['version']:15s} A(first bright)={rA.mean():6.1f} sd {rA.std():4.1f} | B(media time, median)={rm.mean():6.1f} sd {rm.std():4.1f} | B(mean)={rmean.mean():6.1f} | B(p10)={rl.mean():6.1f} | cb interval med {np.median(iv):.1f} ms, frames {len(T)} | media steps {steps} | first bright frame late by (ms) {late.astype(int).tolist()}")
for t in sys.argv[1:]: run(t)
