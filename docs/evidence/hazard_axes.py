# Reproduces the pre-refactor WorldHazardMap geometry (commit 27e809d) to show the portrait axis bug.
# Run: python3 docs/evidence/hazard_axes.py   (needs numpy)
# Reproduces WorldHazardMap.recomputeZones + ProximityStateMachine for a phone held
# in PORTRAIT. ARKit camera space: +x along the device long edge (points DOWN in
# portrait, home-side), +y points to the user's RIGHT in portrait, +z out of the screen.
import numpy as np
def pose(pitch_deg=0.0, h=1.3):
    # User faces world -Z, gravity-aligned world (+Y up). Portrait, pitched down by pitch.
    x = np.array([0,-1,0.]); y = np.array([1,0,0.]); z = np.array([0,0,1.])
    p = np.radians(pitch_deg)   # rotate about camera y (the lateral axis) to pitch down
    R = np.array([[1,0,0],[0,np.cos(p),-np.sin(p)],[0,np.sin(p),np.cos(p)]])  # about world X
    cols = [R@x, R@y, R@z]
    T = np.eye(4); T[:3,0],T[:3,1],T[:3,2] = cols; T[:3,3] = [0,h,0]; return T
def zone(T, world, radius=0.15):
    l = np.linalg.inv(T) @ np.append(world,1); lx,lz = l[0],l[2]
    fwd = -lz; dist = max(0, np.hypot(lx,lz)-radius); bearing = np.degrees(np.arctan2(lx,fwd))
    region = 'left' if bearing < -25 else ('right' if bearing > 25 else 'center')
    corridor = abs(lx) <= 0.5 and fwd > 0
    if abs(bearing) > 100 or fwd < -0.5:          # rearCutoffDeg / behind-the-user skip
        return dist, bearing, '-', False, 'skipped (treated as behind)'
    in_path = abs(bearing) <= 30
    raw = 'CRITICAL' if dist<=0.5 else 'NEAR' if dist<=1.0 else 'CAUTION' if dist<=2.0 else 'CLEAR'
    if not in_path and raw in ('NEAR','CRITICAL'): raw='CAUTION'
    return dist, bearing, region, corridor, raw
cases = {
 'wall 1.0 m to the RIGHT, 0.2 m ahead, chest height': np.array([1.0,1.3,-0.2]),
 'wall 0.8 m to the LEFT, level with user, chest height': np.array([-0.8,1.3,0.0]),
 'pole 2.0 m straight ahead, chest height':           np.array([0,1.3,-2.0]),
 'box top 1.2 m straight ahead, 0.3 m off the floor':  np.array([0,0.3,-1.2]),
 'branch 1.5 m straight ahead, head height 1.8 m':     np.array([0,1.8,-1.5]),
}
for pitch in (0,30):
    T = pose(pitch); print(f'\n--- phone portrait, pitched down {pitch} deg ---')
    for name,w in cases.items():
        true_d = max(0,np.hypot(w[0],w[2])-0.15); true_b = np.degrees(np.arctan2(w[0],-w[2]))
        d,b,r,c,s = zone(T,w)
        print(f'{name:55s} TRUE dist {true_d:4.2f} bearing {true_b:+6.1f} | CODE dist {d:4.2f} bearing {b:+6.1f} region {r:6s} corridor {c!s:5s} -> {s}')
