import hashlib,json
from pathlib import Path
import pytest
import torch
from zyren_train.policies.visual import create_policy
from zyren_train.warm_start import actor_state_for_normalization,initialize_actor,validate_initial_actor
from zyren_train.train import TrainingConfig
from zyren_train.checkpoint import TrainingCheckpoint
from zyren_train.run_manifest import RunDirectory
from training_support import configuration


def policy(family='guard',visual=False,mean=None,scale=None):
    schemas=json.loads((Path(__file__).parent/'fixtures/policy-schemas.json').read_text())[family]
    if visual:
        camera=json.loads((Path(__file__).parent/'fixtures/visual-profiles.json').read_text())['guard-visual-depth']
        schemas={**schemas,'observation_schema':camera['observation'],'observation_schema_hash':camera['observation_hash'],'visual_profile':camera['visual_profile']}
        network={'architecture':'native-camera-cnn-v1','channels':2,'body_width':8,'lstm_hidden_size':128}
    else:network={'hidden_sizes':[128,128],'lstm_hidden_size':128}
    width=sum(f['width'] for f in schemas['observation_schema']['fields'])
    value=create_policy(network,width,schemas['action_space'],observation_schema=schemas['observation_schema'],visual_profile=schemas.get('visual_profile'),fallback=schemas['action_schema']['fallbackDiscrete'],mean=mean,scale=scale)
    return value,schemas,network


@pytest.mark.parametrize('family,visual',[('guard',False),('vehicle',False),('guard',True)])
def test_rebase_preserves_actor_and_recurrence_with_varied_finite_inputs(family,visual):
    torch.set_num_threads(1);torch.manual_seed(11);source,info,network=policy(family,visual);width=source.width;prefix=width-8 if visual else 0
    source.observation_mean[prefix:]=torch.linspace(-2,2,width-prefix);source.observation_scale[prefix:]=torch.linspace(.1,2,width-prefix)
    target,_,_=policy(family,visual);target.observation_mean[prefix:]=torch.linspace(1,-1,width-prefix);target.observation_scale[prefix:]=torch.linspace(.2,3,width-prefix)
    critic=target.value_head.weight.detach().clone();mean=target.observation_mean.clone();source_snapshot={k:v.clone() for k,v in source.state_dict().items()}
    target.load_state_dict(actor_state_for_normalization(target,source.state_dict()))
    assert torch.equal(target.value_head.weight,critic) and torch.equal(target.observation_mean,mean)
    assert all(torch.equal(source.state_dict()[k],v) for k,v in source_snapshot.items())
    for batch in [1,4]:
        hidden=torch.randn(batch,128);cell=torch.randn(batch,128)
        for tick in range(5):
            observation=torch.randn(batch,width)*[.1,1,10,100,1000][tick]
            if visual:observation[:,:prefix]=torch.rand(batch,prefix)
            with torch.no_grad():left=source.step(observation,(hidden,cell),torch.full((batch,),tick==0));right=target.step(observation,(hidden,cell),torch.full((batch,),tick==0))
            torch.testing.assert_close(left[0],right[0],atol=1e-5,rtol=1e-4)
            for a,b in zip(left[2],right[2]):torch.testing.assert_close(a,b,atol=1e-5,rtol=1e-4)
            hidden,cell=left[2]


def initial_fixture(tmp_path):
    executable=tmp_path/'bin/probe';executable.parent.mkdir();executable.write_bytes(b'pure-policy-fixture');lib=tmp_path/'lib';lib.mkdir();(lib/'probe').write_bytes(b'fixture')
    original=configuration([str(executable)],steps=8);source,info,_=policy();data=original.data
    data['scenarios'][0]['observation_schema_hash']=info['observation_schema_hash'];data['scenarios'][0]['action_schema_hash']=info['action_schema_hash'];config=TrainingConfig.from_dict(data)
    config_path=tmp_path/'source-config.json';config_path.write_bytes(config.encoded)
    run=RunDirectory(tmp_path/'source',config.hash);optimizer=torch.optim.Adam(source.parameters());optimizer.zero_grad();source.action_head.weight.sum().backward();optimizer.step()
    checkpoint=TrainingCheckpoint.save(run,policy=source,optimizer=optimizer,steps=8,updates=1,curriculum={},normalization=None,config_hash=config.hash,source_pins={},cloning_progress={'epoch':0,'sequence':0,'complete':True})
    pin={'config':str(config_path),'config_sha256':hashlib.sha256(config_path.read_bytes()).hexdigest(),'checkpoint':str(checkpoint.path),'checkpoint_sha256':checkpoint.sha256}
    target_data={**data,'initial_actor':pin};target_config=TrainingConfig.from_dict(target_data);return source,info,config,target_config,pin


def test_pinned_actor_initialization_is_fresh_optimizer_and_new_lineage(tmp_path):
    source,info,original,config,pin=initial_fixture(tmp_path);target,_,_=policy();critic=target.value_head.weight.detach().clone()
    lineage=initialize_actor(config,target,info)
    assert lineage['source_config_hash']==original.hash and lineage['source_checkpoint_sha256']==pin['checkpoint_sha256']
    assert lineage['optimizer_reset'] and lineage['critic_reset'] and lineage['recurrent_reset']
    assert torch.equal(target.action_head.weight,source.action_head.weight) and torch.equal(target.value_head.weight,critic)
    assert torch.optim.Adam(target.parameters()).state=={}
    assert config.hash!=original.hash


@pytest.mark.parametrize('failure',['changed-weight','changed-config','foreign-config','shape','nonfinite','timing','action','observation','cadence','fixed-hz','encoder','heldout','symlink'])
def test_invalid_initial_actor_rejected_before_target_mutation(tmp_path,failure):
    source,info,original,config,pin=initial_fixture(tmp_path);data=config.data;checkpoint=Path(pin['checkpoint']);config_path=Path(pin['config'])
    if failure=='changed-weight':checkpoint.write_bytes(checkpoint.read_bytes()+b'x')
    elif failure=='changed-config':config_path.write_bytes(config_path.read_bytes()+b' ')
    elif failure in ['foreign-config','shape','nonfinite']:
        value=torch.load(checkpoint,weights_only=True)
        if failure=='foreign-config':value['config_hash']='f'*64
        elif failure=='shape':value['model']['lstm.weight_ih']=torch.zeros(1,1)
        else:value['model']['action_head.bias'][0]=float('nan')
        torch.save(value,checkpoint);data['initial_actor']['checkpoint_sha256']=hashlib.sha256(checkpoint.read_bytes()).hexdigest()
    elif failure in ['timing','action','observation','cadence','fixed-hz','encoder','heldout']:
        value=original.data
        if failure=='timing':value['scenarios'][0]['latency_ticks']+=1
        elif failure=='action':value['scenarios'][0]['action_schema_hash']='a'*64
        elif failure=='observation':value['scenarios'][0]['observation_schema_hash']='b'*64
        elif failure=='cadence':value['scenarios'][0]['control_cadence']+=1
        elif failure=='fixed-hz':value['scenarios'][0]['settings']['fixed_hz']=51
        elif failure=='encoder':value['network']={'architecture':'native-camera-cnn-v1','channels':2,'body_width':8,'lstm_hidden_size':128}
        else:value['scenarios'][0]['partition']='test'
        config_path.write_text(json.dumps(value,separators=(',',':')));data['initial_actor']['config_sha256']=hashlib.sha256(config_path.read_bytes()).hexdigest()
        if failure!='heldout':
            state=torch.load(checkpoint,weights_only=True);state['config_hash']=TrainingConfig.from_dict(value).hash;torch.save(state,checkpoint);data['initial_actor']['checkpoint_sha256']=hashlib.sha256(checkpoint.read_bytes()).hexdigest()
    else:
        link=tmp_path/'alias.pt';link.symlink_to(checkpoint);data['initial_actor']['checkpoint']=str(link)
    target,_,_=policy();before={k:v.clone() for k,v in target.state_dict().items()}
    with pytest.raises(ValueError):initialize_actor(TrainingConfig.from_dict(data),target,info)
    assert all(torch.equal(target.state_dict()[k],v) for k,v in before.items())


def test_initial_descriptor_closed_shape_and_digest():
    for value in [None,{}, {'config':'x','checkpoint':'y','config_sha256':'z','checkpoint_sha256':'a'*64},{'config':'x','checkpoint':'y','config_sha256':'a'*64,'checkpoint_sha256':'b'*64,'optimizer':True}]:
        with pytest.raises(ValueError):validate_initial_actor(value)


def test_real_frozen_worker_warm_start_resets_optimizer_then_resumes(tmp_path,worker_command):
    from zyren_train.train import WorkerPool,train
    from training_support import ROOT
    source_config=configuration(worker_command,steps=8);source_file=tmp_path/'source-config.json';source_file.write_bytes(source_config.encoded)
    source_run=RunDirectory(tmp_path/'source',source_config.hash);source_pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=source_config)
    source_final=train(source_config,source_pool,source_run);source=TrainingCheckpoint.load(source_run,source_config.hash)
    initial={'config':str(source_file),'config_sha256':hashlib.sha256(source_file.read_bytes()).hexdigest(),'checkpoint':str(source_run.path/source_final['checkpoint']),'checkpoint_sha256':source_final['checkpoint_sha256']}
    config=TrainingConfig.from_dict({**source_config.data,'initial_actor':initial});run=RunDirectory(tmp_path/'warm',config.hash)
    pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config);first=train(config,pool,run,cancelled=lambda:True)
    warmed=TrainingCheckpoint.load(run,config.hash)
    assert first['state']=='cancelled' and first['steps']==first['updates']==0 and first['worker_exit_codes']==[0]
    assert warmed['optimizer']['state']=={} and torch.equal(warmed['model']['action_head.weight'],source['model']['action_head.weight'])
    assert not torch.equal(warmed['model']['value_head.weight'],source['model']['value_head.weight'])
    lineage=next(r for r in run.read_receipts() if r.get('phase')=='initial-actor');assert lineage['source_checkpoint_sha256']==source_final['checkpoint_sha256'] and lineage['optimizer_reset']
    resumed=RunDirectory(run.path,config.hash,resume=True);pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config);final=train(config,pool,resumed,resume=True)
    after=TrainingCheckpoint.load(resumed,config.hash)
    assert final['state']=='completed' and final['steps']==8 and final['updates']==1 and final['worker_exit_codes']==[0]
    assert max(float(v['step']) for v in after['optimizer']['state'].values())==2
    assert len([r for r in resumed.read_receipts() if r.get('phase')=='initial-actor'])==1
    assert hashlib.sha256(Path(initial['checkpoint']).read_bytes()).hexdigest()==initial['checkpoint_sha256']


@pytest.mark.parametrize('field,value',[('observation_scale',0),('observation_scale',-1),('observation_mean',float('nan'))])
def test_rebase_rejects_invalid_normalization_without_mutation(field,value):
    source,_,_=policy();target,_,_=policy();model={k:v.clone() for k,v in source.state_dict().items()};model[field][0]=value;before={k:v.clone() for k,v in target.state_dict().items()}
    with pytest.raises(ValueError):actor_state_for_normalization(target,model)
    assert all(torch.equal(target.state_dict()[k],v) for k,v in before.items())
