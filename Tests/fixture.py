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
request={'requestId':'test-request','senderId':'U_TEST_ONLY','accountId':'test-account','createdAt':'2026-09-16T10:00:00Z','expiresAt':'2026-09-16T11:00:00Z','metadata':{'name':'Test fixture, not a Slack user'}}
if args[:2]==['gateway','call']:
 method=args[2];params=json.loads(args[args.index('--params')+1])
 if profile=='auth-failure': print('unauthorized: test');sys.exit(1)
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
