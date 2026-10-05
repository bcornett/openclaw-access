#!/usr/bin/python3
# Isolated test double. Never connects to OpenClaw or Slack.
import sys,json,os,time
args=sys.argv[1:]
profile=''
if args[:1]==['--profile']:
 profile=args[1];args=args[2:]
if profile=='timeout': time.sleep(10)
if profile=='arguments':
 print(json.dumps({'args':args}));sys.exit()
# Scheduled jobs. Shapes follow OpenClaw's cron.list, cron.update, and cron.remove gateway schema.
def job(id,name,schedule,enabled=True,payload=None,**extra):
 row={'id':id,'name':name,'enabled':enabled,'schedule':schedule,'sessionTarget':'isolated','wakeMode':'now','createdAtMs':1757000000000,'updatedAtMs':1757000000000,
  'payload':payload or {'kind':'agentTurn','message':'Test fixture prompt for '+name+'.'},'state':{}}
 row.update(extra);return row
def at(expr,**more): return dict({'kind':'cron','expr':expr},**more)
JOBS=[
 job('test-monday-report','Test fixture: Monday report',at('0 8 * * 1',tz='America/Chicago',staggerMs=0),configRevision='rev-1',lastRunStatus='ok',lastRunAtMs=1758546000000,nextRunAtMs=1759150800000,description='Fixture job, not a real schedule'),
 job('test-interval','Test fixture: interval check',{'kind':'every','everyMs':1800000,'anchorMs':1757000000000},payload={'kind':'systemEvent','text':'Test fixture event'}),
 job('test-paused','Test fixture: paused digest',at('0 17 * * MON-FRI'),enabled=False,configRevision='rev-3')]
DEMO=[
 job('fx-1','Test fixture: Monday pipeline report',at('0 8 * * 1'),configRevision='r1',lastRunStatus='ok',description='Fixture job, not a real schedule'),
 job('fx-2','Test fixture: Monday proposal summary',at('0 8 * * 1'),configRevision='r1',lastRunStatus='ok'),
 job('fx-3','Test fixture: Monday invoice digest',at('5 8 * * 1'),configRevision='r1',lastRunStatus='ok'),
 job('fx-4','Test fixture: Weekday inbox sweep',at('0 8 * * 1-5'),configRevision='r1',lastRunStatus='ok'),
 job('fx-5','Test fixture: Nightly backup check',at('30 2 * * *'),configRevision='r1',lastRunStatus='ok'),
 job('fx-6','Test fixture: Friday wrap-up',at('0 16 * * 5'),configRevision='r1',lastRunStatus='error',lastRunError='Test fixture error: delivery target not found'),
 job('fx-7','Test fixture: Health ping',{'kind':'every','everyMs':1800000},payload={'kind':'systemEvent','text':'Test fixture event'}),
 job('fx-8','Test fixture: Quarterly reminder',at('0 9 1 */3 *'),configRevision='r1'),
 job('fx-9','Test fixture: Paused digest',at('0 17 * * 1-5'),enabled=False,configRevision='r1'),
 job('fx-10','Test fixture: Heartbeat monitor',{'kind':'every','everyMs':3600000},payload={'kind':'heartbeat'})]
STATE=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','build','tests','fixture-state.json')
def upcoming(row):
 # Enough of a clock for the stateful profile: one time of day on chosen weekdays, or an interval.
 import datetime
 s=row['schedule'];now=datetime.datetime.now()
 if not row['enabled']: return None
 if s['kind']=='every': return int(time.time()*1000)+s['everyMs']
 f=s.get('expr','').split()
 if len(f)!=5 or not (f[0]+f[1]).isdigit() or f[2:4]!=['*','*']: return None
 days=set()
 for part in f[4].split(','):
  if part=='*': days|=set(range(7))
  elif '-' in part: a,b=part.split('-');days|=set(range(int(a),int(b)+1))
  else: days.add(int(part)%7)
 for d in range(8):
  t=(now+datetime.timedelta(days=d)).replace(hour=int(f[1]),minute=int(f[0]),second=0,microsecond=0)
  if t>now and (t.weekday()+1)%7 in days: return int(t.timestamp()*1000)
def cron(method,params):
 stateful=profile=='schedules'
 jobs=json.load(open(STATE)) if stateful and os.path.exists(STATE) else json.loads(json.dumps(DEMO if stateful else JOBS))
 if stateful:
  for row in jobs:
   row.pop('nextRunAtMs',None);due=upcoming(row)
   if due: row['nextRunAtMs']=due
 if method=='cron.list':
  assert params.get('includeDisabled')==True and set(params)<={'includeDisabled','offset'}
  if profile=='paged':
   offset=params.get('offset',0);assert offset in (0,2)
   print(json.dumps({'jobs':jobs[offset:offset+2],'total':3,'offset':offset,'limit':2,'hasMore':offset==0,'nextOffset':2 if offset==0 else None}))
  elif profile=='no-jobs': print(json.dumps({'total':0}))
  else: print('Test startup notice\n'+json.dumps({'jobs':jobs,'total':len(jobs),'offset':0,'limit':50,'hasMore':False,'nextOffset':None}))
  return
 if method=='cron.remove':
  # Only the id is sent. An unknown id is an error, as on the gateway.
  assert set(params)=={'id'}
  if profile=='unconfirmed': print(json.dumps({'ok':True,'removed':False}));return
  found=[r for r in jobs if r['id']==params['id']]
  if not found: print('unknown cron job id: '+params['id']);sys.exit(1)
  jobs.remove(found[0])
  if stateful: os.makedirs(os.path.dirname(STATE),exist_ok=True);json.dump(jobs,open(STATE,'w'))
  result={'ok':True,'removed':True}
  if params['id']=='test-interval': result['activeRunCancellationRequested']=True
  print(json.dumps(result));return
 assert method=='cron.update' and set(params)<={'id','patch','expectedConfigRevision'}
 if profile=='conflict': print('cron job definition no longer matches the loaded version; review the latest version before retrying');sys.exit(1)
 row=next(r for r in jobs if r['id']==params['id']);patch=params['patch']
 # The revision is sent only when the gateway reported one, and must match it.
 assert params.get('expectedConfigRevision')==row.get('configRevision')
 assert len(patch)==1 and set(patch)<={'schedule','enabled'}
 if 'enabled' in patch: assert type(patch['enabled']) is bool;row['enabled']=patch['enabled']
 else:
  new=patch['schedule'];old=row['schedule'];assert new['kind']==old['kind']
  if new['kind']=='cron':
   assert set(new)<={'kind','expr','tz','staggerMs'} and new['expr'].strip() and new.get('staggerMs')==old.get('staggerMs')
   if params['id']=='test-monday-report': assert new=={'kind':'cron','expr':'0 3 * * 1','tz':'America/Chicago','staggerMs':0}
  else: assert set(new)<={'kind','everyMs','anchorMs'} and new['everyMs']>=1 and new.get('anchorMs')==old.get('anchorMs')
  row['schedule']=new
 if 'configRevision' in row: row['configRevision']+='+'
 if stateful: os.makedirs(os.path.dirname(STATE),exist_ok=True);json.dump(jobs,open(STATE,'w'))
 print(json.dumps(row))
request={'requestId':'test-request','senderId':'U_TEST_ONLY','accountId':'test-account','createdAt':'2026-09-16T10:00:00Z','expiresAt':'2026-09-16T11:00:00Z','metadata':{'name':'Test fixture, not a Slack user'}}
if args[:2]==['gateway','call']:
 method=args[2];params=json.loads(args[args.index('--params')+1])
 if profile=='auth-failure': print('unauthorized: test');sys.exit(1)
 if method.startswith('cron.'): cron(method,params);sys.exit()
 if profile=='legacy': print('unknown method: '+method);sys.exit(1)
 assert params['channel']=='slack'
 if method=='channels.pairing.list': print('Test startup notice\n'+json.dumps({'requests':[request]}))
 else:
  assert params['requestId']=='test-request' and params['accountId']=='test-account'
  if method.endswith('approve'): assert params['notify']==False and params['bootstrapCommandOwner']==False
  else: assert method.endswith('dismiss') and 'notify' not in params
  print(json.dumps({'requestId':'test-request','senderId':'U_TEST_ONLY'}))
elif args[:3]==['pairing','list','slack']:
 print(json.dumps({'requests':[{'id':'U_TEST_ONLY','code':'TESTCODE','meta':{'accountId':'test-account'}}]}))
elif args[:3]==['pairing','approve','slack']:
 assert args[3:]==['TESTCODE','--account','test-account'];print('Approved test fixture')
else: raise Exception(args)
