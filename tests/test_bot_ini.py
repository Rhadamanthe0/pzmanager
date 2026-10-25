from contextlib import ExitStack
from pathlib import Path
import tempfile,unittest
from unittest.mock import patch
from test_sec_markdown import bot,_serveur

class ConfiguredIni(unittest.TestCase):
 def test_missing_configured_ini_never_borrows_other_world_or_caches_it(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);server=root/'Server';server.mkdir()
   expected=server/'configured-world.ini';other=server/'servertest.ini'
   other.write_text('MaxPlayers=99\nMaxPacketsPerSecond=100\n')
   previous={}
   with ExitStack() as stack:
    stack.enter_context(patch.dict(bot.os.environ,{'PZ_INI_PATH':str(expected),'PZ_SERVER_NAME':'configured-world'}))
    stack.enter_context(patch.object(bot,'PZ_SOURCE_DIR',str(root)))
    for name,value in {'jvm_status':{'pid':None,'invocation':None,'service_state':'inactive'},'_meminfo':{},'_service_memory':{},'_percpu_stat':None,'_temps':{},'_gc_heap':None,'_recent_heapdump':None,'_online_players':None,'_default_iface':None,'_prom_snapshot':None}.items():
     stack.enter_context(patch.object(bot,name,return_value=value))
    first=dict(bot.collect_stats(previous))
    expected.write_text('MaxPlayers=12\nMaxPacketsPerSecond=1000\n')
    second=bot.collect_stats(previous)
    view=_serveur('fixture');view.update(second,game_net={'pps_sent':1,'pps_recv':2,'recv_pps_max_client':50,'recv_pps_max_name':'fixture'})
    field=next(field['value'] for field in bot._monitoring_embed(view).fields if field['name']=='Serveur')
    row=dict(zip(bot._CSV_HEADER,bot._csv_row(view)))
    print('FIRST caps',first['max_players'],first['max_pps'],'SECOND caps',second['max_players'],second['max_pps'],'EMBED',field,'CSV ratio',row['recv_cap_pct'],flush=True)
    self.assertIsNone(first['max_players'])
    self.assertIsNone(first['max_pps'],'missing configured INI borrowed an unrelated world cap')
    self.assertEqual(second['max_players'],12)
    self.assertEqual(second['max_pps'],1000,'created configured INI was ignored')
    self.assertIn('max **5%** du cap',field)
    self.assertEqual(row['recv_cap_pct'],'5.0')
 def test_direct_module_fallback_derives_only_source_and_server_name(self):
  with tempfile.TemporaryDirectory() as temp,patch.object(bot,'PZ_SOURCE_DIR',temp),patch.dict(bot.os.environ,{'PZ_INI_PATH':'','PZ_SERVER_NAME':'selected'}):
   server=Path(temp)/'Server';server.mkdir()
   (server/'servertest.ini').write_text('MaxPlayers=99\n')
   self.assertEqual(bot._server_ini_path(),str(server/'selected.ini'))
   with patch.dict(bot.os.environ,{'PZ_SERVER_NAME':''}):
    self.assertEqual(bot._server_ini_path(),str(server/'servertest.ini'))

if __name__=='__main__':unittest.main()
