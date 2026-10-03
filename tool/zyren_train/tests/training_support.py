from pathlib import Path
import hashlib
from zyren_train.train import TrainingConfig,worker_native_hashes
from zyren_train.scenario import ScenarioSpec

ROOT=Path(__file__).resolve().parents[3]


def configuration(command,*,scenario='guard',steps=16,datasets=None,bc_epochs=0):
    spec=ScenarioSpec.from_dict(__import__('json').loads((ROOT/f'examples/game_lab/game/scenarios/{scenario}.json').read_text()))
    return TrainingConfig.from_dict({'schema_version':1,'seed':7,'device':'cpu','algorithm':'recurrent_ppo',
        'network':{'hidden_sizes':[128,128],'lstm_hidden_size':128},
        'optimizer':{'learning_rate':.0003,'epochs':2,'gamma':.99,'gae_lambda':.95,'clip':.2,'entropy':.01,'value':.5,'max_grad_norm':.5},
        'rollout':{'environments':1,'steps':8},'total_steps':steps,'checkpoint_every_steps':8,'evaluation_every_steps':1000,
        'scenarios':[spec.to_dict()],'curriculum':[{'name':'occlusion' if scenario=='guard' else 'static-obstacles','scenario':scenario,'after_steps':0}],
        'rewards':{'task.progress':1},'datasets':datasets or {'train':[],'validation':[],'test':[]},'bc_epochs':bc_epochs,
        'worker_sha256':hashlib.sha256(Path(command[0]).read_bytes()).hexdigest(),'worker_native_sha256':worker_native_hashes(command[0])})
