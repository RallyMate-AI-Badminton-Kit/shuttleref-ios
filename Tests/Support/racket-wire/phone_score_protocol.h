#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
namespace phonescore {
enum class Op {Invalid,Configure,Ready,Stop,Ack};
struct Command {Op op=Op::Invalid;char context[33]={},match[37]={},device[13]={},boot[17]={},owner[37]={},side=0,status[12]={},reason[24]={};uint32_t association=0,lease=0,seq=0,revision=0;};
inline bool hexString(const char* s,size_t n){if(strlen(s)!=n)return false;for(size_t i=0;i<n;i++)if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return false;return true;}
inline bool uuid(const char*s){if(strlen(s)!=36)return false;for(unsigned i=0;i<36;i++){if(i==8||i==13||i==18||i==23){if(s[i]!='-')return false;}else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return false;}return true;}
// A bounded flat-object decoder: this protocol contains only ASCII identifiers,
// enums and unsigned integers. Escapes are decoded before duplicate-key checking.
class Object {
 struct Field {char key[24]={},value[64]={};bool number=false;uint32_t integer=0;};
 Field fields[12];size_t used=0,pos=0,len=0;const char* input=nullptr;
 void ws(){while(pos<len&&(input[pos]==' '||input[pos]=='\r'||input[pos]=='\n'||input[pos]=='\t'))++pos;}
 bool take(char c){ws();if(pos>=len||input[pos]!=c)return false;++pos;return true;}
 static int nibble(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;}
 bool str(char* out,size_t cap){if(!take('"'))return false;size_t n=0;while(pos<len){unsigned ch=(unsigned char)input[pos++];if(ch=='"'){out[n]=0;return true;}if(ch=='\\'){if(pos==len)return false;ch=(unsigned char)input[pos++];if(ch=='u'){unsigned v=0;for(int i=0;i<4;i++){if(pos==len)return false;int h=nibble(input[pos++]);if(h<0)return false;v=v*16+unsigned(h);}ch=v;}else if(ch!='"'&&ch!='\\'&&ch!='/')return false;}
 if(ch<32||ch>126||n+1>=cap)return false;out[n++]=char(ch);}return false;}
public:
 bool parse(const char* s,size_t n){if(!s||n==0||n>512)return false;input=s;len=n;pos=used=0;if(!take('{'))return false;
  while(true){if(used==12)return false;Field& f=fields[used];f=Field{};if(!str(f.key,sizeof f.key)||!take(':'))return false;for(size_t i=0;i<used;i++)if(!strcmp(fields[i].key,f.key))return false;ws();if(pos==len)return false;
   if(input[pos]=='"'){if(!str(f.value,sizeof f.value))return false;}else{f.number=true;size_t first=pos;uint64_t v=0;while(pos<len&&input[pos]>='0'&&input[pos]<='9'){if(pos>first&&input[first]=='0')return false;v=v*10+unsigned(input[pos++]-'0');if(v>UINT32_MAX)return false;}if(pos==first)return false;f.integer=uint32_t(v);}
   ++used;ws();if(pos<len&&input[pos]=='}'){++pos;ws();return pos==len;}if(!take(','))return false;
  }
 }
 size_t count()const{return used;}
 const Field* get(const char*k)const{for(size_t i=0;i<used;i++)if(!strcmp(fields[i].key,k))return &fields[i];return nullptr;}
 bool text(const char*k,char*out,size_t cap)const{auto f=get(k);if(!f||f->number||strlen(f->value)>=cap)return false;strcpy(out,f->value);return true;}
 bool num(const char*k,uint32_t&v)const{auto f=get(k);if(!f||!f->number)return false;v=f->integer;return true;}
};
inline bool decode(const char*s,size_t n,Command& c){
 c=Command{};Object o;if(!o.parse(s,n))return false;uint32_t version=0;char type[16];if(!o.num("v",version)||version!=1||!o.text("type",type,sizeof type)||!o.text("context",c.context,sizeof c.context)||!hexString(c.context,32))return false;
 if(!strcmp(type,"configure")){c.op=Op::Configure;char side[2];if(o.count()!=9||!o.text("match_id",c.match,sizeof c.match)||!uuid(c.match)||!o.text("device",c.device,sizeof c.device)||!hexString(c.device,12)||!o.text("boot",c.boot,sizeof c.boot)||!hexString(c.boot,16)||!o.text("owner",c.owner,sizeof c.owner)||!uuid(c.owner)||!o.text("side",side,2)||(side[0]!='r'&&side[0]!='b')||!o.num("association_revision",c.association))return false;c.side=side[0];return true;}
 if(!strcmp(type,"ready")){c.op=Op::Ready;return o.count()==4&&o.num("lease",c.lease)&&c.lease>0;}
 if(!strcmp(type,"stop")){c.op=Op::Stop;return o.count()==3;}
 if(!strcmp(type,"ack")){c.op=Op::Ack;if(o.count()!=7||!o.num("seq",c.seq)||!c.seq||!o.num("revision",c.revision)||!o.text("status",c.status,sizeof c.status)||!o.text("reason",c.reason,sizeof c.reason))return false;
  if(!strcmp(c.status,"committed"))return !strcmp(c.reason,"ok");
  if(!strcmp(c.status,"unknown"))return !strcmp(c.reason,"storage_uncertain");
  if(strcmp(c.status,"rejected"))return false;
  const char* reasons[]={"not_ready","stale_lease","match_closed","no_undo","identity_changed","invalid_event","storage_failed"};for(auto r:reasons)if(!strcmp(r,c.reason))return true;
 }
 return false;
}
class Fragments {
 char bytes[513]={};size_t length=0;uint8_t tx=0,next=0,count=0;uint32_t start=0;
public:
 void reset(){length=0;next=count=0;}
 const char* data()const{return bytes;}size_t size()const{return length;}
 bool push(const uint8_t*p,size_t n,uint32_t now){
  if(!p||n<4||n>20){reset();return false;}
  if(p[1]==0){reset();tx=p[0];count=p[2];start=now;}
  if(!count||count>31||p[0]!=tx||p[1]!=next||p[2]!=count||p[1]>=count||uint32_t(now-start)>=2000||(p[1]+1<count&&n!=20)||length+n-3>512){reset();return false;}
  memcpy(bytes+length,p+3,n-3);length+=n-3;bytes[length]=0;++next;
  return next==count;
 }
};
inline void put32(uint8_t*p,uint32_t n){p[0]=n>>24;p[1]=n>>16;p[2]=n>>8;p[3]=n;}
inline void fromHex(const char*s,uint8_t*out,size_t n){for(size_t i=0;i<n;i++){auto val=[](char c){return c<='9'?c-'0':c-'a'+10;};out[i]=uint8_t(val(s[i*2])*16+val(s[i*2+1]));}}
}
