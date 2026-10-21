# Reproduces the pre-refactor cluster-sphere distance (commit 27e809d) on a synthetic hallway.
# Run: python3 docs/evidence/cluster_radius.py   (needs numpy)
# Port of SpatialAlgorithms.cluster (voxel 0.15, 26-neighbour BFS, minPoints 10) plus the
# WorldHazardMap radius rule radius = max(0.15, |maxBound-minBound|/2), distance = range - radius.
# Synthetic hallway: user at origin facing -Z, walls at x = +/-1.0 m, floor y = 0.
import numpy as np, itertools
rng = np.random.default_rng(0)
def wall(x, n=1500): return np.c_[np.full(n,x)+rng.normal(0,.01,n), rng.uniform(0,2.2,n), -rng.uniform(0.6,4.0,n)]
def floorpts(n=2500): return np.c_[rng.uniform(-1,1,n), rng.normal(0,.01,n), -rng.uniform(0.9,4.0,n)]
def cluster(pts, voxel=0.15, minp=10):
    keys = {}
    for i,k in enumerate(map(tuple, np.floor(pts/voxel).astype(int))): keys.setdefault(k,[]).append(i)
    seen=set(); out=[]
    for s in keys:
        if s in seen: continue
        st=[s]; seen.add(s); idx=[]
        while st:
            k=st.pop(); idx+=keys[k]
            for d in itertools.product((-1,0,1),repeat=3):
                nk=(k[0]+d[0],k[1]+d[1],k[2]+d[2])
                if nk in keys and nk not in seen: seen.add(nk); st.append(nk)
        if len(idx)>=minp: out.append(pts[idx])
    return out
def report(title, pts):
    print(title)
    for c in cluster(pts):
        lo,hi=c.min(0),c.max(0); r=max(.15,np.linalg.norm(hi-lo)/2); cen=c.mean(0)
        horiz=np.hypot(cen[0],cen[2]); d=max(0,horiz-r)
        true_near=np.hypot(c[:,0],c[:,2]).min()
        print(f'  cluster n={len(c):5d} centroid=({cen[0]:+.2f},{cen[1]:.2f},{cen[2]:+.2f}) radius={r:.2f}  CODE distance={d:.2f}  TRUE nearest={true_near:.2f}')
W = np.r_[wall(1.0), wall(-1.0)]
report('floor found -> elevated = walls only', W[W[:,1]>0.06])
report('floor NOT found -> elevated = every point (code path: elevated = pointsForGeom)', np.r_[W, floorpts()])
