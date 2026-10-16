import java.nio.file.*;
import java.lang.reflect.*;
import java.lang.constant.*;
import java.util.function.Predicate;
import java.util.*;
import java.util.jar.*;

/** Instrument only a private class copy, never the installed JAR. Reflection
 * keeps --release compatibility: ClassFile API on JDK 24+, ASM on older JDKs.
 * Missing APIs or a changed loader layout fail closed. */
public final class InstrumentItemReads {
    private static Class<?> type(String name) throws Exception {
        return Class.forName("jdk.internal.org.objectweb.asm." + name);
    }
    private static Object node(String name, Class<?>[] signature, Object... args) throws Exception {
        return type("tree." + name).getConstructor(signature).newInstance(args);
    }
    private static Object var(int opcode, int slot) throws Exception {
        return node("VarInsnNode", new Class<?>[]{int.class,int.class}, opcode,slot);
    }
    private static Object call(String name, String descriptor) throws Exception {
        return node("MethodInsnNode",new Class<?>[]{int.class,String.class,String.class,String.class,boolean.class},
                    184,"NativeItemTrace",name,descriptor,false);
    }
    private static Object list(Object... instructions) throws Exception {
        Object list=type("tree.InsnList").getConstructor().newInstance();
        for(Object instruction:instructions)
            list.getClass().getMethod("add",type("tree.AbstractInsnNode")).invoke(list,instruction);
        return list;
    }
    private static byte[] modern(byte[] bytes) throws Exception {
        Class<?> cf=Class.forName("java.lang.classfile.ClassFile"), cm=Class.forName("java.lang.classfile.ClassModel");
        Class<?> ct=Class.forName("java.lang.classfile.CodeTransform"), cb=Class.forName("java.lang.classfile.CodeBuilder");
        Class<?> transform=Class.forName("java.lang.classfile.ClassTransform"), mm=Class.forName("java.lang.classfile.MethodModel");
        Class<?> utf=Class.forName("java.lang.classfile.constantpool.Utf8Entry");
        Class<?> invoke=Class.forName("java.lang.classfile.instruction.InvokeInstruction"), instruction=Class.forName("java.lang.classfile.Instruction");
        Class<?> member=Class.forName("java.lang.classfile.constantpool.ClassEntry");
        int[] counts={0,0,0};
        Predicate<Object> wanted=method->{try {
            String name=(String)utf.getMethod("stringValue").invoke(mm.getMethod("methodName").invoke(method));
            String desc=(String)utf.getMethod("stringValue").invoke(mm.getMethod("methodType").invoke(method));
            boolean yes=name.equals("loadItem") && desc.equals("(Ljava/nio/ByteBuffer;IZLzombie/inventory/InventoryItem;)Lzombie/inventory/InventoryItem;");
            if(yes) counts[0]++; return yes;
        } catch(Exception e) {throw new IllegalStateException(e);}};
        ClassDesc buffer=ClassDesc.of("java.nio.ByteBuffer"), hook=ClassDesc.of("NativeItemTrace");
        Method emit=cb.getMethod("invokestatic",ClassDesc.class,String.class,MethodTypeDesc.class);
        Method with=Arrays.stream(cb.getMethods()).filter(m->m.getName().equals("with")&&m.getParameterCount()==1).findFirst().orElseThrow();
        Object code=Proxy.newProxyInstance(ct.getClassLoader(),new Class<?>[]{ct},(proxy,method,args)->{
            if(method.getName().equals("atStart")) {
                Object b=args[0];cb.getMethod("aload",int.class).invoke(b,0);cb.getMethod("iload",int.class).invoke(b,1);
                emit.invoke(b,hook,"enter",MethodTypeDesc.of(ConstantDescs.CD_void,buffer,ConstantDescs.CD_int));return null;
            }
            if(method.getName().equals("atEnd")) return null;
            if(!method.getName().equals("accept")) throw new IllegalStateException("Unexpected transform callback");
            Object b=args[0],e=args[1];
            String opcode=instruction.isInstance(e)?instruction.getMethod("opcode").invoke(e).toString():"";
            if(opcode.equals("ARETURN")) {
                counts[2]++;cb.getMethod("dup").invoke(b);cb.getMethod("aload",int.class).invoke(b,0);
                emit.invoke(b,hook,"exit",MethodTypeDesc.of(ConstantDescs.CD_void,ClassDesc.of("zombie.inventory.InventoryItem"),buffer));
            }
            with.invoke(b,e);
            if(opcode.equals("INVOKEVIRTUAL") && invoke.isInstance(e)) {
                String owner=(String)member.getMethod("asInternalName").invoke(invoke.getMethod("owner").invoke(e));
                String name=(String)utf.getMethod("stringValue").invoke(invoke.getMethod("name").invoke(e));
                String desc=(String)utf.getMethod("stringValue").invoke(invoke.getMethod("type").invoke(e));
                if(owner.equals("zombie/inventory/InventoryItem") && name.equals("load") && desc.equals("(Ljava/nio/ByteBuffer;I)V")) {
                    counts[1]++;cb.getMethod("aload",int.class).invoke(b,0);
                    emit.invoke(b,hook,"consumed",MethodTypeDesc.of(ConstantDescs.CD_void,buffer));
                }
            }
            return null;
        });
        Object engine=cf.getMethod("of").invoke(null), model=cf.getMethod("parse",byte[].class).invoke(engine,(Object)bytes);
        Object action=transform.getMethod("transformingMethodBodies",Predicate.class,ct).invoke(null,wanted,code);
        byte[] result=(byte[])cf.getMethod("transformClass",cm,transform).invoke(engine,model,action);
        if(counts[0]!=1||counts[1]!=1||counts[2]!=2) throw new IllegalStateException("Unsupported native loader layout");
        return result;
    }
    public static void main(String[] args) throws Exception {
        if(args.length!=2) throw new IllegalArgumentException("JAR PRIVATE_CLASSES required");
        byte[] bytes;
        try(JarFile jar=new JarFile(args[0])) {
            try(var in=jar.getInputStream(jar.getJarEntry("zombie/inventory/InventoryItem.class"))) { bytes=in.readAllBytes(); }
        }
        if(Runtime.version().feature()>=24) {
            Path out=Path.of(args[1],"zombie/inventory/InventoryItem.class");Files.createDirectories(out.getParent());
            Files.write(out,modern(bytes));return;
        }
        Object reader=type("ClassReader").getConstructor(byte[].class).newInstance((Object)bytes);
        Object cls=type("tree.ClassNode").getConstructor().newInstance();
        reader.getClass().getMethod("accept",type("ClassVisitor"),int.class).invoke(reader,cls,0);
        int methods=0, calls=0, returns=0;
        for(Object method:(List<?>)cls.getClass().getField("methods").get(cls)) {
            String name=(String)method.getClass().getField("name").get(method);
            String desc=(String)method.getClass().getField("desc").get(method);
            if(!name.equals("loadItem") || !desc.equals("(Ljava/nio/ByteBuffer;IZLzombie/inventory/InventoryItem;)Lzombie/inventory/InventoryItem;")) continue;
            methods++;
            Object insns=method.getClass().getField("instructions").get(method);
            Object[] original=(Object[])insns.getClass().getMethod("toArray").invoke(insns);
            var insertBefore=insns.getClass().getMethod("insertBefore",type("tree.AbstractInsnNode"),type("tree.InsnList"));
            var insertAfter=insns.getClass().getMethod("insert",type("tree.AbstractInsnNode"),type("tree.InsnList"));
            insertBefore.invoke(insns,original[0],list(var(25,0),var(21,1),call("enter","(Ljava/nio/ByteBuffer;I)V")));
            for(Object instruction:original) {
                int opcode=(int)instruction.getClass().getMethod("getOpcode").invoke(instruction);
                if(opcode==182 && instruction.getClass().getSimpleName().equals("MethodInsnNode")) {
                    String owner=(String)instruction.getClass().getField("owner").get(instruction);
                    String called=(String)instruction.getClass().getField("name").get(instruction);
                    String signature=(String)instruction.getClass().getField("desc").get(instruction);
                    if(owner.equals("zombie/inventory/InventoryItem") && called.equals("load") && signature.equals("(Ljava/nio/ByteBuffer;I)V")) {
                        calls++;
                        insertAfter.invoke(insns,instruction,list(var(25,0),call("consumed","(Ljava/nio/ByteBuffer;)V")));
                    }
                }
                if(opcode==176) {
                    returns++;
                    insertBefore.invoke(insns,instruction,list(node("InsnNode",new Class<?>[]{int.class},89),var(25,0),
                        call("exit","(Lzombie/inventory/InventoryItem;Ljava/nio/ByteBuffer;)V")));
                }
            }
        }
        if(methods!=1 || calls!=1 || returns!=2) throw new IllegalStateException("Unsupported native loader layout");
        Object writer=type("ClassWriter").getConstructor(int.class).newInstance(1); // COMPUTE_MAXS; no new locals/branches
        cls.getClass().getMethod("accept",type("ClassVisitor")).invoke(cls,writer);
        Path out=Path.of(args[1],"zombie/inventory/InventoryItem.class");Files.createDirectories(out.getParent());
        Files.write(out,(byte[])writer.getClass().getMethod("toByteArray").invoke(writer));
    }
}
