# -*- coding: utf-8 -*-
"""
Created on Wed May 13 18:10:53 2020

@author: luzhiwei
"""

    
    
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
df=pd.read_csv('test.csv')
print(df)
#df['分类']=df.score.map(lambda number:number+1)
df['new_score']=df.score.map(lambda number:number+1)
print(df)
fig=plt.figure()
x=np.random.randn(100)
y=np.random.randn(100)
colors=np.random.rand(100)
size=np.random.rand(100)*100
plt.scatter(x,y,c=colors,s=size,alpha=0.9)

fig.savefig('C:/Users/luzhiwei/Desktop/cwy/fi.png')
#fig=plt.figure()
#df=pd.DataFrame(np.random.randn(100,4),columns=['A','B','C','D'])
#df.hist(column='A',figsize=(100,50))
#fig.savefig('C:/Users/luzhiwei/Desktop/cwy/fi.png')