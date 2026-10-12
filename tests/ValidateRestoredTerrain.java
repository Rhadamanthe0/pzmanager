/** Offline probe for selected copied Build 42 chunks using the installed game JAR.
 * Run from a private directory with read-only media/ and stdlib.lua available.
 * Does not load Workshop script definitions or render tiles; it is a record-loader
 * check, not a substitute for a full server/client integration test.
 */
import java.nio.*;import java.nio.file.*;import java.lang.reflect.*;
import zombie.iso.*;import zombie.network.GameServer;import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;import se.krka.kahlua.j2se.J2SEPlatform;
public class ValidateRestoredTerrain {
 public static void main(String[] args)throws Exception {
  if(args.length!=3)throw new IllegalArgumentException("Usage: ValidateRestoredTerrain CHUNK_PATH CHUNK_X CHUNK_Y");
  // Load copied records only: no server loop, networking, regeneration or save().
  zombie.core.random.RandStandard.INSTANCE.init();
  zombie.core.random.RandLua.INSTANCE.init();
  GameServer.server=true; LuaManager.platform=J2SEPlatform.getInstance();
  LuaManager.env=LuaManager.platform.newTable();
  ZomboidFileSystem.instance.setCacheDir(Path.of("cache").toAbsolutePath().toString());
  ZomboidFileSystem.instance.init();
  LuaManager.init();
  Class<?> dictClass=Class.forName("zombie.world.DictionaryData");
  Constructor<?> ctor=dictClass.getDeclaredConstructor();ctor.setAccessible(true);Object dictionary=ctor.newInstance();
  Method dictLoad=dictClass.getDeclaredMethod("loadFromByteBuffer",ByteBuffer.class);dictLoad.setAccessible(true);
  Path world=Path.of(args[0]).getParent().getParent().getParent();
  dictLoad.invoke(dictionary,ByteBuffer.wrap(Files.readAllBytes(world.resolve("WorldDictionary.bin"))));
  Field data=zombie.world.WorldDictionary.class.getDeclaredField("data");data.setAccessible(true);data.set(null,dictionary);
  new zombie.erosion.season.ErosionIceQueen(zombie.iso.sprite.IsoSpriteManager.instance);
  zombie.erosion.ErosionRegions.init();
  IsoCell cell=new IsoCell(1,1); IsoWorld.instance.currentCell=cell;
  IsoChunk chunk=new IsoChunk(cell); chunk.wx=Integer.parseInt(args[1]);chunk.wy=Integer.parseInt(args[2]);
  Method load=IsoChunk.class.getDeclaredMethod("LoadFromDiskOrBufferInternal",ByteBuffer.class);load.setAccessible(true);
  try {load.invoke(chunk,ByteBuffer.wrap(Files.readAllBytes(Path.of(args[0]))));}
  catch(InvocationTargetException e){throw new RuntimeException(e.getCause());}
  int objects=0,thumpables=0,floors=0,doors=0;
  for(var level:chunk.squares)for(var square:level)if(square!=null)for(int i=0;i<square.getObjects().size();i++){
   var object=square.getObjects().get(i);
   objects++; if(object instanceof zombie.iso.objects.IsoThumpable built) { thumpables++;if(built.isFloor())floors++;if(built.isDoor())doors++; }
  }
  System.out.println("{\"objects\":"+objects+",\"thumpables\":"+thumpables+",\"floors\":"+floors+",\"doors\":"+doors+"}");
 }
}
